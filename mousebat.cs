// mousebat — native Logitech mouse battery tray utility.
// Reads battery directly over HID++ from the receiver (works with G HUB closed),
// falls back to the G HUB agent's local websocket, draws one numeric tray icon,
// shows full/low toasts, logs a CSV history, charts it, and edits thresholds from
// a double-click dialog. Compiles with the built-in csc.exe to a ~20 KB exe.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Windows.Forms.DataVisualization.Charting;
using Timer = System.Windows.Forms.Timer;

namespace MouseBat
{
    class Reading { public string Name; public int Percent; public bool Charging; }
    class ReadResult { public bool Reachable; public string Source = ""; public List<Reading> Mice = new List<Reading>(); }

    static class Paths
    {
        public static readonly string Dir = AppDomain.CurrentDomain.BaseDirectory;
        public static readonly string Csv = Path.Combine(Dir, "battery-history.csv");
        public static readonly string State = Path.Combine(Dir, "battery-state.json");
        public static readonly string Settings = Path.Combine(Dir, "mousebat-settings.json");
        public static readonly string Chart = Path.Combine(Dir, "battery-chart.png");
        public static readonly string Log = Path.Combine(Dir, "mousebat.log");
        public static readonly string Armed = Path.Combine(Dir, ".armed");
    }

    static class Util
    {
        public static void Log(string m) { try { File.AppendAllText(Paths.Log, DateTime.Now.ToString("HH:mm:ss") + "  " + m + "\r\n"); } catch { } }
    }

    class App : ApplicationContext
    {
        double FullMin = 95, LowThresh = 5, LowRearm = 10;
        readonly Dictionary<string, NotifyIcon> icons = new Dictionary<string, NotifyIcon>();
        readonly Dictionary<string, bool> prevCharging = new Dictionary<string, bool>();
        readonly Dictionary<string, bool> lowFired = new Dictionary<string, bool>();
        readonly Dictionary<string, string> lastRow = new Dictionary<string, string>();
        Dictionary<string, Reading> state = new Dictionary<string, Reading>();
        string ghubName;
        bool? srvUp;
        Timer timer;
        static readonly int[] MvLUT = {
            4186,4156,4143,4133,4122,4113,4103,4094,4086,4075,4067,4059,4051,4043,4035,4027,4019,4011,4003,3997,
            3989,3983,3976,3969,3961,3955,3949,3942,3935,3929,3922,3916,3909,3902,3896,3890,3883,3877,3870,3865,
            3859,3853,3848,3842,3837,3833,3828,3824,3819,3815,3811,3808,3804,3800,3797,3793,3790,3787,3784,3781,
            3778,3775,3772,3770,3767,3764,3762,3759,3757,3754,3751,3748,3744,3741,3737,3734,3730,3726,3724,3720,
            3717,3714,3710,3706,3702,3697,3693,3688,3683,3677,3671,3666,3662,3658,3654,3646,3633,3612,3579,3537 };
        int sw;

        [STAThread]
        static void Main(string[] args)
        {
            if (args.Length > 0 && args[0].Equals("-Chart", StringComparison.OrdinalIgnoreCase)) { BuildChart(); OpenChart(); return; }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new App());
        }

        App()
        {
            LoadSettings(); LoadState(); SeedFromCsv();
            Util.Log("mousebat starting (native, HID++ + GHub fallback)");
            Poll();
            if (!File.Exists(Paths.Armed))
            {
                Toast("Mouse battery watcher armed", "Pings on full charge and below " + LowThresh + "%.");
                try { File.WriteAllText(Paths.Armed, ""); } catch { }
            }
            timer = new Timer { Interval = 60000 };
            timer.Tick += (s, e) => Poll();
            timer.Start();
        }

        // --- reader dispatch: HID++ first, G HUB websocket fallback ---------
        ReadResult GetReadings()
        {
            Reading hid = null;
            try { hid = ReadHidpp(); } catch { }
            if (hid != null)
            {
                if (ghubName != null) hid.Name = ghubName;
                else { var k = state.Keys.ToList(); hid.Name = k.Count == 1 ? k[0] : "Logitech Mouse"; }
                return new ReadResult { Reachable = true, Source = "hidpp", Mice = new List<Reading> { hid } };
            }
            var g = ReadGHub();
            foreach (var m in g.Mice) ghubName = m.Name;
            return g;
        }

        // --- direct HID++ ----------------------------------------------------
        int LutPercent(int mv) { for (int i = 0; i < MvLUT.Length; i++) if (mv > MvLUT[i]) return MvLUT.Length - i; return 0; }

        byte[] Hidpp(IntPtr h, byte dev, byte feat, byte func, byte[] pars)
        {
            sw = (sw % 15) + 1; byte s = (byte)sw;
            while (Native.Read(h, 0) != null) { }   // flush stale reports
            byte[] req = new byte[20];
            req[0] = 0x11; req[1] = dev; req[2] = feat; req[3] = (byte)((func << 4) | s);
            for (int i = 0; i < pars.Length && i < 16; i++) req[4 + i] = pars[i];
            if (!Native.Write(h, req)) return null;
            for (int t = 0; t < 16; t++)
            {
                byte[] r = Native.Read(h, 500);
                if (r == null) return null;
                if (r.Length < 5 || r[1] != dev) continue;
                if (r[2] == 0xFF && r[3] == feat && (r[4] & 0x0F) == s) return null;  // HID++ error
                if (r[2] == feat && (r[3] & 0x0F) == s) return r;
            }
            return null;
        }
        int FeatureIndex(IntPtr h, byte dev, int fid)
        {
            byte[] r = Hidpp(h, dev, 0, 0, new byte[] { (byte)((fid >> 8) & 0xFF), (byte)(fid & 0xFF) });
            return r != null ? r[4] : 0;
        }
        Reading ReadHidpp()
        {
            string path = Native.FindLongHidpp();
            if (path == null) return null;
            IntPtr h = Native.Open(path);
            if (h == (IntPtr)(-1) || h == IntPtr.Zero) return null;
            try
            {
                foreach (byte dev in new byte[] { 1, 2, 0xFF })
                {
                    int fi = FeatureIndex(h, dev, 0x1001);
                    if (fi == 0) continue;
                    byte[] r = Hidpp(h, dev, (byte)fi, 0, new byte[0]);
                    if (r == null) continue;
                    int mv = (r[4] << 8) | r[5];
                    if (mv < 2000) continue;   // implausible (stale/zero)
                    int flags = r[6];
                    bool charging = (flags & 0x80) != 0 && ((flags & 0x07) == 0 || (flags & 0x07) == 1);
                    return new Reading { Percent = LutPercent(mv), Charging = charging };
                }
                return null;
            }
            finally { Native.CloseHandle(h); }
        }

        // --- G HUB websocket fallback ---------------------------------------
        static void WsSend(ClientWebSocket ws, string json)
        {
            try { var b = Encoding.UTF8.GetBytes(json); ws.SendAsync(new ArraySegment<byte>(b), WebSocketMessageType.Text, true, CancellationToken.None).Wait(2000); } catch { }
        }
        static string WsRecv(ClientWebSocket ws, int ms)
        {
            try
            {
                var buf = new byte[32768]; var sb = new StringBuilder();
                while (true)
                {
                    var t = ws.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None);
                    if (!t.Wait(ms)) return null;
                    var r = t.Result;
                    sb.Append(Encoding.UTF8.GetString(buf, 0, r.Count));
                    if (r.EndOfMessage) break;
                }
                return sb.ToString();
            }
            catch { return null; }
        }
        static Dictionary<string, object> AsObj(object o) { return o as Dictionary<string, object>; }
        ReadResult ReadGHub()
        {
            var res = new ReadResult { Source = "ghub" };
            var ws = new ClientWebSocket();
            ws.Options.AddSubProtocol("json");
            ws.Options.SetRequestHeader("Origin", "file://");
            try
            {
                if (!ws.ConnectAsync(new Uri("ws://127.0.0.1:9010"), CancellationToken.None).Wait(3000)) return res;
                if (ws.State != WebSocketState.Open) return res;
                res.Reachable = true;
                var ser = new JavaScriptSerializer();
                WsSend(ws, "{\"msgId\":\"\",\"verb\":\"GET\",\"path\":\"/devices/list\"}");
                object[] devs = null;
                for (int i = 0; i < 12 && devs == null; i++)
                {
                    string m = WsRecv(ws, 1500); if (m == null) break;
                    var o = ser.Deserialize<Dictionary<string, object>>(m);
                    if (o.ContainsKey("path") && (o["path"] as string) == "/devices/list")
                    {
                        var p = AsObj(o["payload"]);
                        if (p != null && p.ContainsKey("deviceInfos")) devs = p["deviceInfos"] as object[];
                    }
                }
                if (devs == null) return res;
                var want = new Dictionary<string, string>();
                foreach (var di in devs)
                {
                    var d = AsObj(di); if (d == null) continue;
                    var caps = d.ContainsKey("capabilities") ? AsObj(d["capabilities"]) : null;
                    bool hasBatt = caps != null && caps.ContainsKey("hasBatteryStatus") && Convert.ToBoolean(caps["hasBatteryStatus"]);
                    string type = d.ContainsKey("deviceType") ? Convert.ToString(d["deviceType"]) : "";
                    if (hasBatt && type.ToUpperInvariant().Contains("MOUSE"))
                    {
                        string id = Convert.ToString(d["id"]);
                        want[id] = d.ContainsKey("extendedDisplayName") ? Convert.ToString(d["extendedDisplayName"]) : "Logitech Mouse";
                        WsSend(ws, "{\"msgId\":\"\",\"verb\":\"GET\",\"path\":\"/battery/" + id + "/state\"}");
                    }
                }
                var seen = new HashSet<string>();
                for (int i = 0; i < 24 && seen.Count < want.Count; i++)
                {
                    string m = WsRecv(ws, 1500); if (m == null) break;
                    var o = ser.Deserialize<Dictionary<string, object>>(m);
                    string path = o.ContainsKey("path") ? o["path"] as string : null;
                    if (path != null && path.StartsWith("/battery/") && o.ContainsKey("payload"))
                    {
                        var p = AsObj(o["payload"]);
                        if (p != null && p.ContainsKey("deviceId") && p.ContainsKey("percentage") && p["percentage"] != null)
                        {
                            string id = Convert.ToString(p["deviceId"]);
                            if (want.ContainsKey(id) && !seen.Contains(id))
                            {
                                seen.Add(id);
                                res.Mice.Add(new Reading { Name = want[id], Percent = Convert.ToInt32(p["percentage"]), Charging = p.ContainsKey("charging") && Convert.ToBoolean(p["charging"]) });
                            }
                        }
                    }
                }
                return res;
            }
            catch { return res; }
            finally { try { ws.Dispose(); } catch { } }
        }

        // --- poll ------------------------------------------------------------
        void Poll()
        {
            ReadResult res;
            try { res = GetReadings(); } catch { return; }
            if (!res.Reachable) { if (srvUp != false) { Util.Log("no battery source (mouse off HID++ and G HUB down)"); srvUp = false; } }
            else if (res.Mice.Count > 0) { if (srvUp != true) { Util.Log("battery source up (" + res.Source + ")"); srvUp = true; } }

            var fresh = new HashSet<string>();
            foreach (var m in res.Mice)
            {
                fresh.Add(m.Name);
                state[m.Name] = m;
                WriteData(m);
                string status = m.Charging ? (m.Percent >= FullMin ? "full" : "charging") : "discharging";
                UpdateIcon(m.Name, m.Percent, status, false);
                bool prev; prevCharging.TryGetValue(m.Name, out prev);
                if (prev && !m.Charging && m.Percent >= FullMin) Toast(m.Name + " fully charged", m.Name + " at " + m.Percent + "% - unplug it.");
                bool lf; lowFired.TryGetValue(m.Name, out lf);
                if (!m.Charging && m.Percent < LowThresh && !lf) { Toast(m.Name + " battery low", m.Name + " at " + m.Percent + "% - charge it."); lowFired[m.Name] = true; }
                if (m.Charging || m.Percent >= LowRearm) lowFired[m.Name] = false;
                prevCharging[m.Name] = m.Charging;
            }
            foreach (var kv in state)
            {
                if (fresh.Contains(kv.Key)) continue;
                var c = kv.Value;
                string status = c.Charging ? (c.Percent >= FullMin ? "full" : "charging") : "discharging";
                UpdateIcon(kv.Key, c.Percent, status, true);
            }
            SaveState();
        }

        // --- tray icon -------------------------------------------------------
        void UpdateIcon(string name, int pct, string status, bool stale)
        {
            NotifyIcon ni;
            if (!icons.TryGetValue(name, out ni))
            {
                ni = new NotifyIcon();
                var menu = new ContextMenuStrip();
                menu.Items.Add("Settings...", null, (s, e) => ShowSettings());
                menu.Items.Add("Battery chart", null, (s, e) => { BuildChart(); OpenChart(); });
                menu.Items.Add("Exit", null, (s, e) => ExitApp());
                ni.ContextMenuStrip = menu;
                ni.DoubleClick += (s, e) => ShowSettings();
                ni.Visible = true;
                icons[name] = ni;
            }
            Icon old = ni.Icon;
            ni.Icon = MakeIcon(pct, status);
            if (old != null) { Native.DestroyIcon(old.Handle); old.Dispose(); }
            string tip = name + " - " + pct + "% (" + status + ")" + (stale ? " - last known" : "");
            if (tip.Length > 63) tip = tip.Substring(0, 63);
            ni.Text = tip;
        }
        Icon MakeIcon(int pct, string status)
        {
            var bmp = new Bitmap(32, 32);
            var g = Graphics.FromImage(bmp);
            g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.Transparent);
            Color col;
            if (status == "full") col = Color.FromArgb(39, 174, 96);
            else if (status == "charging") col = Color.FromArgb(41, 128, 185);
            else if (pct >= 60) col = Color.FromArgb(46, 204, 113);
            else if (pct >= 30) col = Color.FromArgb(243, 156, 18);
            else col = Color.FromArgb(231, 76, 60);
            using (var br = new SolidBrush(col)) g.FillEllipse(br, 0, 0, 31, 31);
            string label = pct >= 100 ? "F" : pct.ToString();
            int fpx = label.Length >= 3 ? 13 : label.Length == 2 ? 17 : 21;
            using (var font = new Font("Segoe UI", fpx, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString(label, font, Brushes.White, new RectangleF(0, 0, 32, 32), sf);
            g.Dispose();
            IntPtr hicon = bmp.GetHicon();
            bmp.Dispose();
            return Icon.FromHandle(hicon);
        }
        void Toast(string title, string text)
        {
            var ni = icons.Values.FirstOrDefault();
            if (ni == null) return;
            ni.BalloonTipIcon = ToolTipIcon.Info; ni.BalloonTipTitle = title; ni.BalloonTipText = text;
            try { ni.ShowBalloonTip(5000); } catch { }
        }
        void ExitApp()
        {
            if (timer != null) timer.Stop();
            foreach (var ni in icons.Values) { ni.Visible = false; if (ni.Icon != null) Native.DestroyIcon(ni.Icon.Handle); ni.Dispose(); }
            ExitThread();
        }

        // --- CSV + caches ----------------------------------------------------
        void WriteData(Reading m)
        {
            string key = m.Percent + "|" + m.Charging;
            string last;
            if (lastRow.TryGetValue(m.Name, out last) && last == key) return;
            lastRow[m.Name] = key;
            try
            {
                if (!File.Exists(Paths.Csv)) File.AppendAllText(Paths.Csv, "timestamp,name,percent,charging\r\n");
                File.AppendAllText(Paths.Csv, DateTimeOffset.Now.ToString("o") + "," + m.Name.Replace(",", " ") + "," + m.Percent + "," + m.Charging + "\r\n");
            }
            catch { }
        }
        void LoadState()
        {
            state = new Dictionary<string, Reading>();
            try
            {
                if (!File.Exists(Paths.State)) return;
                var o = new JavaScriptSerializer().Deserialize<Dictionary<string, Dictionary<string, object>>>(File.ReadAllText(Paths.State));
                foreach (var kv in o) state[kv.Key] = new Reading { Name = kv.Key, Percent = Convert.ToInt32(kv.Value["Percent"]), Charging = Convert.ToBoolean(kv.Value["Charging"]) };
            }
            catch { }
        }
        void SaveState()
        {
            try
            {
                var sb = new StringBuilder("{"); bool first = true;
                foreach (var kv in state)
                {
                    if (!first) sb.Append(","); first = false;
                    sb.Append("\"" + kv.Key.Replace("\"", "") + "\":{\"Percent\":" + kv.Value.Percent + ",\"Charging\":" + (kv.Value.Charging ? "true" : "false") + "}");
                }
                sb.Append("}");
                File.WriteAllText(Paths.State, sb.ToString());
            }
            catch { }
        }
        void SeedFromCsv()
        {
            if (File.Exists(Paths.State) || !File.Exists(Paths.Csv)) return;
            try
            {
                foreach (var line in File.ReadAllLines(Paths.Csv).Skip(1))
                {
                    var p = line.Split(','); if (p.Length < 4) continue;
                    int pct; if (!int.TryParse(p[2], out pct)) continue;
                    state[p[1]] = new Reading { Name = p[1], Percent = pct, Charging = p[3].Trim() == "True" };
                }
                if (state.Count > 0) SaveState();
            }
            catch { }
        }

        // --- settings --------------------------------------------------------
        void LoadSettings()
        {
            try
            {
                if (!File.Exists(Paths.Settings)) return;
                var o = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(Paths.Settings));
                if (o.ContainsKey("FullMin")) FullMin = Convert.ToDouble(o["FullMin"]);
                if (o.ContainsKey("LowThresh")) LowThresh = Convert.ToDouble(o["LowThresh"]);
                if (o.ContainsKey("LowRearm")) LowRearm = Convert.ToDouble(o["LowRearm"]);
            }
            catch { }
        }
        void SaveSettings()
        {
            var ic = CultureInfo.InvariantCulture;
            try { File.WriteAllText(Paths.Settings, "{\"FullMin\":" + FullMin.ToString(ic) + ",\"LowThresh\":" + LowThresh.ToString(ic) + ",\"LowRearm\":" + LowRearm.ToString(ic) + "}"); } catch { }
        }
        NumericUpDown AddNud(Form f, string text, int y, int min, int max, int val)
        {
            f.Controls.Add(new Label { Text = text, Bounds = new Rectangle(14, y + 3, 220, 20) });
            var nud = new NumericUpDown { Bounds = new Rectangle(236, y, 60, 24), Minimum = min, Maximum = max, DecimalPlaces = 0 };
            nud.Value = Math.Min(Math.Max(val, min), max);
            f.Controls.Add(nud); return nud;
        }
        void ShowSettings()
        {
            using (var f = new Form())
            {
                f.Text = "Mouse Battery - notification thresholds";
                f.ClientSize = new Size(310, 170);
                f.FormBorderStyle = FormBorderStyle.FixedDialog; f.StartPosition = FormStartPosition.CenterScreen;
                f.MaximizeBox = false; f.MinimizeBox = false; f.TopMost = true; f.ShowInTaskbar = false;
                var nLow = AddNud(f, "Low battery warning at (%):", 20, 1, 50, (int)LowThresh);
                var nRe = AddNud(f, "Re-arm low warning above (%):", 52, 1, 60, (int)LowRearm);
                var nFull = AddNud(f, "Full charge at (%):", 84, 50, 100, (int)FullMin);
                var ok = new Button { Text = "Save", Bounds = new Rectangle(135, 128, 75, 28), DialogResult = DialogResult.OK };
                var cn = new Button { Text = "Cancel", Bounds = new Rectangle(218, 128, 75, 28), DialogResult = DialogResult.Cancel };
                f.Controls.Add(ok); f.Controls.Add(cn); f.AcceptButton = ok; f.CancelButton = cn;
                if (f.ShowDialog() == DialogResult.OK)
                {
                    LowThresh = (double)nLow.Value; LowRearm = (double)nRe.Value; FullMin = (double)nFull.Value;
                    SaveSettings();
                    Util.Log("settings updated: low=" + LowThresh + " rearm=" + LowRearm + " full=" + FullMin);
                }
            }
        }

        // --- chart -----------------------------------------------------------
        static void BuildChart()
        {
            if (!File.Exists(Paths.Csv)) { Util.Log("chart: no history yet"); return; }
            try
            {
                var chart = new Chart { Width = 1000, Height = 420, BackColor = Color.White };
                var area = new ChartArea();
                area.AxisX.Title = "Time"; area.AxisY.Title = "Battery %"; area.AxisY.Minimum = 0; area.AxisY.Maximum = 100;
                area.AxisX.LabelStyle.Format = "MM-dd HH:mm"; area.AxisX.MajorGrid.LineColor = Color.Gainsboro; area.AxisY.MajorGrid.LineColor = Color.Gainsboro;
                chart.ChartAreas.Add(area);
                var title = chart.Titles.Add("Mouse battery history"); title.Font = new Font("Segoe UI", 12, FontStyle.Bold);
                var byName = new Dictionary<string, Series>();
                foreach (var line in File.ReadAllLines(Paths.Csv).Skip(1))
                {
                    var p = line.Split(','); if (p.Length < 4) continue;
                    Series s;
                    if (!byName.TryGetValue(p[1], out s)) { s = new Series(p[1]) { ChartType = SeriesChartType.Line, BorderWidth = 2, XValueType = ChartValueType.DateTime }; byName[p[1]] = s; chart.Series.Add(s); }
                    DateTimeOffset ts; int pct;
                    if (!DateTimeOffset.TryParse(p[0], null, DateTimeStyles.RoundtripKind, out ts)) continue;
                    if (!int.TryParse(p[2], out pct)) continue;
                    s.Points.AddXY(ts.LocalDateTime, pct);
                }
                chart.Legends.Add(new Legend());
                chart.SaveImage(Paths.Chart, ChartImageFormat.Png);
                Util.Log("chart written: " + Paths.Chart);
            }
            catch (Exception e) { Util.Log("chart failed: " + e.Message); }
        }
        static void OpenChart() { try { if (File.Exists(Paths.Chart)) System.Diagnostics.Process.Start(Paths.Chart); } catch { } }
    }

    // --- Win32 HID (HID++ long-report interface) + DestroyIcon --------------
    static class Native
    {
        [StructLayout(LayoutKind.Sequential)] struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }
        [StructLayout(LayoutKind.Sequential)]
        struct HIDP_CAPS
        {
            public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
            public ushort NumberLinkCollectionNodes, a1, a2, a3, a4, a5, a6, a7, a8, a9;
        }
        [StructLayout(LayoutKind.Sequential)] struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid g; public int Flags; public IntPtr Reserved; }
        [StructLayout(LayoutKind.Sequential)] struct OVERLAPPED { public IntPtr Internal, InternalHigh; public uint OffLow, OffHigh; public IntPtr hEvent; }

        [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
        [DllImport("hid.dll")] static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
        [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
        [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr pp);
        [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr pp, out HIDP_CAPS caps);
        [DllImport("setupapi.dll", CharSet = CharSet.Auto)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
        [DllImport("setupapi.dll")] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA data);
        [DllImport("setupapi.dll", CharSet = CharSet.Auto)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DEVICE_INTERFACE_DATA data, IntPtr det, int sz, ref int req, IntPtr di);
        [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)] static extern IntPtr CreateFile(string n, uint a, uint sh, IntPtr se, uint dp, uint fl, IntPtr t);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(IntPtr h, byte[] b, int n, out int w, ref OVERLAPPED o);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(IntPtr h, byte[] b, int n, out int r, ref OVERLAPPED o);
        [DllImport("kernel32.dll")] static extern IntPtr CreateEvent(IntPtr a, bool m, bool i, string n);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll")] static extern bool GetOverlappedResult(IntPtr h, ref OVERLAPPED o, out int n, bool wait);
        [DllImport("kernel32.dll")] static extern bool CancelIo(IntPtr h);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);

        const uint GENR = 0x80000000, GENW = 0x40000000, SHARE = 3, OPEN = 3, OVL = 0x40000000;
        const int PRESENT = 0x2, IFACE = 0x10;

        public static string FindLongHidpp()
        {
            Guid g; HidD_GetHidGuid(out g);
            IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, PRESENT | IFACE);
            try
            {
                for (int i = 0; ; i++)
                {
                    var d = new SP_DEVICE_INTERFACE_DATA(); d.cbSize = Marshal.SizeOf(d);
                    if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d)) break;
                    int req = 0; SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, ref req, IntPtr.Zero);
                    IntPtr det = Marshal.AllocHGlobal(req); Marshal.WriteInt32(det, IntPtr.Size == 8 ? 8 : 6);
                    string path = null;
                    if (SetupDiGetDeviceInterfaceDetail(set, ref d, det, req, ref req, IntPtr.Zero)) path = Marshal.PtrToStringAuto(new IntPtr(det.ToInt64() + 4));
                    Marshal.FreeHGlobal(det);
                    if (path == null) continue;
                    IntPtr h = CreateFile(path, GENR | GENW, SHARE, IntPtr.Zero, OPEN, 0, IntPtr.Zero);
                    if (h == (IntPtr)(-1)) continue;
                    try
                    {
                        var a = new HIDD_ATTRIBUTES(); a.Size = Marshal.SizeOf(a);
                        if (!HidD_GetAttributes(h, ref a) || a.VendorID != 0x046D) continue;
                        IntPtr pp; if (!HidD_GetPreparsedData(h, out pp)) continue;
                        HIDP_CAPS c; HidP_GetCaps(pp, out c); HidD_FreePreparsedData(pp);
                        if (c.UsagePage == 0xFF00 && c.OutputReportByteLength == 20) return path;
                    }
                    finally { CloseHandle(h); }
                }
            }
            finally { SetupDiDestroyDeviceInfoList(set); }
            return null;
        }
        public static IntPtr Open(string path) { return CreateFile(path, GENR | GENW, SHARE, IntPtr.Zero, OPEN, OVL, IntPtr.Zero); }
        public static bool Write(IntPtr h, byte[] data)
        {
            var o = new OVERLAPPED(); o.hEvent = CreateEvent(IntPtr.Zero, true, false, null);
            int w; bool ok = WriteFile(h, data, data.Length, out w, ref o);
            if (!ok && Marshal.GetLastWin32Error() == 997) { WaitForSingleObject(o.hEvent, 1000); ok = GetOverlappedResult(h, ref o, out w, false); }
            CloseHandle(o.hEvent); return ok;
        }
        public static byte[] Read(IntPtr h, uint timeoutMs)
        {
            var o = new OVERLAPPED(); o.hEvent = CreateEvent(IntPtr.Zero, true, false, null);
            byte[] buf = new byte[20]; int r; bool ok = ReadFile(h, buf, 20, out r, ref o);
            if (!ok)
            {
                if (Marshal.GetLastWin32Error() == 997)
                {
                    if (WaitForSingleObject(o.hEvent, timeoutMs) == 0) ok = GetOverlappedResult(h, ref o, out r, false);
                    else { CancelIo(h); CloseHandle(o.hEvent); return null; }
                }
                else { CloseHandle(o.hEvent); return null; }
            }
            CloseHandle(o.hEvent);
            if (!ok) return null;
            byte[] res = new byte[r]; Array.Copy(buf, res, r); return res;
        }
    }
}
