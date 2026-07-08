// mousebat - native Logitech mouse battery tray utility.
// Reads battery directly over HID++ from the receiver (works with G HUB closed),
// falls back to the G HUB agent's local websocket, draws an animated battery tray
// icon, sends graduated low/critical/full nudges (lock-aware, per-tier cadence),
// logs a CSV history, charts it, and edits thresholds from a double-click dialog.
// Compiles with the built-in csc.exe to a ~20 KB exe.
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
using Microsoft.Win32;
using Timer = System.Windows.Forms.Timer;

namespace MouseBat
{
    class Reading { public string Name; public int Percent; public bool Charging; }
    class ReadResult { public bool Reachable; public string Source = ""; public List<Reading> Mice = new List<Reading>(); }
    class IconState { public int Pct; public string Status; }

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
        // nudge cadences (configurable): repeat the alert while the condition holds.
        int NudgeLowStep = 1;             // re-nudge every N% drop below LowThresh
        int NudgeRearmStep = 5;           // re-nudge every N% drop below LowRearm
        int NudgeCritSecs = 15;           // re-nudge every N seconds at/below CritPct
        int NudgeFullMins = 5;            // re-nudge every N minutes while full & charging
        const int CritPct = 1;            // "critical" battery level
        const int NudgeMaxStaleSecs = 70; // stop nudging within ~1 poll of the mouse going quiet
        readonly Dictionary<string, NotifyIcon> icons = new Dictionary<string, NotifyIcon>();
        readonly Dictionary<string, IconState> iconState = new Dictionary<string, IconState>();
        readonly Dictionary<string, int> nudgePct = new Dictionary<string, int>();
        readonly Dictionary<string, DateTime> nudgeTime = new Dictionary<string, DateTime>();
        readonly Dictionary<string, DateTime> lastSeen = new Dictionary<string, DateTime>();
        readonly Dictionary<string, string> lastRow = new Dictionary<string, string>();
        Dictionary<string, Reading> state = new Dictionary<string, Reading>();
        string ghubName;
        bool? srvUp;
        Timer timer, anim, nudgeTimer;
        int frame;                        // tray-icon animation frame counter
        bool locked;                      // workstation session locked (suppress nudges)
        bool autostart = true;            // start with Windows (tray toggle), default on
        bool fastState;                   // currently flagged as draining faster than usual
        DateTime lastFastToast = DateTime.MinValue;
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "mousebat";
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
            try { locked = Native.IsLocked(); } catch { }   // seed lock state (kept live by SessionSwitch)
            ReconcileAutostart();   // re-point the Run key at this exe (handles a moved exe)
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
            anim = new Timer { Interval = 150 };
            anim.Tick += (s, e) => AnimTick();
            anim.Start();
            nudgeTimer = new Timer { Interval = 5000 };
            nudgeTimer.Tick += (s, e) => EvaluateNudges();
            nudgeTimer.Start();
            SystemEvents.SessionSwitch += OnSessionSwitch;
        }

        void OnSessionSwitch(object s, SessionSwitchEventArgs e)
        {
            if (e.Reason == SessionSwitchReason.SessionLock) locked = true;
            else if (e.Reason == SessionSwitchReason.SessionUnlock) locked = false;
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
                    // Unified Battery (0x1004): modern mice report state-of-charge directly as a %.
                    int fu = FeatureIndex(h, dev, 0x1004);
                    if (fu != 0)
                    {
                        byte[] r = Hidpp(h, dev, (byte)fu, 1, new byte[0]);   // func 1 = getStatus
                        if (r != null && r[4] >= 1 && r[4] <= 100)
                        {
                            bool chg = r[6] == 1 || r[6] == 2;                // 0 discharging, 1/2 charging
                            return new Reading { Percent = r[4], Charging = chg };
                        }
                    }
                    // Legacy Battery Voltage (0x1001): older mice report mV, mapped via the LUT.
                    int fi = FeatureIndex(h, dev, 0x1001);
                    if (fi == 0) continue;
                    byte[] rv = Hidpp(h, dev, (byte)fi, 0, new byte[0]);
                    if (rv == null) continue;
                    int mv = (rv[4] << 8) | rv[5];
                    if (mv < 2000) continue;   // implausible (stale/zero)
                    int flags = rv[6];
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
                // JavaScriptSerializer deserializes JSON arrays as ArrayList, not object[],
                // so treat all arrays as IEnumerable (an object[] cast silently yields null).
                System.Collections.IEnumerable devs = null;
                for (int i = 0; i < 12 && devs == null; i++)
                {
                    string m = WsRecv(ws, 1500); if (m == null) break;
                    var o = ser.Deserialize<Dictionary<string, object>>(m);
                    if (o.ContainsKey("path") && (o["path"] as string) == "/devices/list")
                    {
                        var p = AsObj(o["payload"]);
                        if (p != null && p.ContainsKey("deviceInfos")) devs = p["deviceInfos"] as System.Collections.IEnumerable;
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
                lastSeen[m.Name] = DateTime.Now;
                WriteData(m);
                string status = m.Charging ? (m.Percent >= FullMin ? "full" : "charging") : "discharging";
                UpdateIcon(m.Name, m.Percent, status, false);
            }
            foreach (var kv in state)
            {
                if (fresh.Contains(kv.Key)) continue;
                var c = kv.Value;
                string status = c.Charging ? (c.Percent >= FullMin ? "full" : "charging") : "discharging";
                UpdateIcon(kv.Key, c.Percent, status, true);
            }
            EnsurePlaceholder();   // show "?" icon until a mouse reports; removed once one does
            SaveState();
            CheckDrainAnomaly();
            EvaluateNudges();
        }

        // --- graduated, lock-aware battery nudges ---------------------------
        // A nudge repeats while its condition holds. Time-based tiers (crit/full)
        // fire off the cached reading between polls but self-gate by elapsed time
        // and stop within ~one poll of the mouse going quiet (NudgeMaxStaleSecs).
        // Percent-drop tiers (low/rearm) re-arm only once the battery recovers
        // (>= LowRearm or charging), so jitter around a threshold can't spam them.
        string NudgeTier(Reading m)
        {
            if (m.Charging) return m.Percent >= FullMin ? "full" : null;
            if (m.Percent <= CritPct) return "crit";
            if (m.Percent < LowThresh) return "low";
            if (m.Percent < LowRearm) return "rearm";
            return null;
        }
        void EvaluateNudges()
        {
            if (locked) return;
            var now = DateTime.Now;
            foreach (var kv in state)
            {
                string name = kv.Key; Reading m = kv.Value;
                DateTime seen;
                if (!lastSeen.TryGetValue(name, out seen)) continue;
                if ((now - seen).TotalSeconds > NudgeMaxStaleSecs) continue;   // quiet / gone
                string tier = NudgeTier(m);
                if (tier == null) { nudgePct[name] = -1; continue; }           // recovered: re-arm %-tiers

                DateTime last; if (!nudgeTime.TryGetValue(name, out last)) last = DateTime.MinValue;
                bool fire;
                if (tier == "full") fire = (now - last).TotalMinutes >= NudgeFullMins;
                else if (tier == "crit") fire = (now - last).TotalSeconds >= NudgeCritSecs;
                else
                {
                    int step = tier == "low" ? NudgeLowStep : NudgeRearmStep;
                    int lp; if (!nudgePct.TryGetValue(name, out lp)) lp = -1;
                    fire = lp < 0 || lp - m.Percent >= step;   // fire on entry, then every step% dropped
                }
                if (!fire) continue;
                nudgeTime[name] = now;
                if (tier == "full") ToastOn(name, m.Name + " fully charged", m.Name + " at " + m.Percent + "% - unplug it.");
                else if (tier == "crit") ToastOn(name, m.Name + " critically low", m.Name + " at " + m.Percent + "% - charge now.");
                else { nudgePct[name] = m.Percent; ToastOn(name, m.Name + " battery low", m.Name + " at " + m.Percent + "% - charge it."); }
            }
        }

        // --- automatic "draining faster than usual" detection ---------------
        void CheckDrainAnomaly()
        {
            double? ratio = AnalyzeDischarge();
            if (ratio.HasValue && ratio.Value >= 1.4)
            {
                if (!locked && !fastState && (DateTime.Now - lastFastToast).TotalHours >= 6)
                {
                    Toast("Battery draining faster than usual", string.Format(CultureInfo.InvariantCulture, "Recent drain is {0:N1}x your usual rate.", ratio.Value));
                    lastFastToast = DateTime.Now;
                }
                fastState = true;
            }
            else if (!ratio.HasValue || ratio.Value < 1.2) { fastState = false; }   // re-arm
        }
        // Duration-weighted active drain ratio: recent (<=24 h) vs baseline (older).
        // Sleep intervals (< 0.5 %/hr) are excluded so idle time never skews it.
        // Returns null until there is enough active history on each side.
        double? AnalyzeDischarge()
        {
            string[] lines;
            try { if (!File.Exists(Paths.Csv)) return null; lines = File.ReadAllLines(Paths.Csv); } catch { return null; }
            var ts = new List<DateTimeOffset>(); var pct = new List<int>(); var chg = new List<bool>();
            for (int i = 1; i < lines.Length; i++)
            {
                var p = lines[i].Split(','); if (p.Length < 4) continue;
                DateTimeOffset t; int v;
                if (!DateTimeOffset.TryParse(p[0], null, DateTimeStyles.RoundtripKind, out t)) continue;
                if (!int.TryParse(p[2], out v)) continue;
                ts.Add(t); pct.Add(v); chg.Add(p[3].Trim() == "True");
            }
            if (ts.Count < 2) return null;
            const double sleepThresh = 0.5, recentHours = 24, minActiveHours = 3;
            var now = DateTimeOffset.Now;
            double rD = 0, rH = 0, bD = 0, bH = 0;
            for (int i = 1; i < ts.Count; i++)
            {
                if (chg[i - 1] || chg[i]) continue;
                int drop = pct[i - 1] - pct[i]; if (drop <= 0) continue;
                double h = (ts[i] - ts[i - 1]).TotalHours; if (h <= 0) continue;
                if (drop / h < sleepThresh) continue;   // sleep interval
                if ((now - ts[i]).TotalHours <= recentHours) { rD += drop; rH += h; } else { bD += drop; bH += h; }
            }
            if (rH < minActiveHours || bH < minActiveHours) return null;
            double baseRate = bD / bH; if (baseRate <= 0) return null;
            return (rD / rH) / baseRate;
        }

        // --- tray icon -------------------------------------------------------
        const string PlaceholderKey = "\0placeholder";

        NotifyIcon NewTrayIcon()
        {
            var ni = new NotifyIcon();
            var menu = new ContextMenuStrip();
            menu.Items.Add("Settings...", null, (s, e) => ShowSettings());
            var auto = new ToolStripMenuItem("Start with Windows", null, (s, e) => ToggleAutostart());
            menu.Items.Add(auto);
            menu.Items.Add("Battery chart", null, (s, e) => { BuildChart(); OpenChart(); });
            menu.Items.Add("Exit", null, (s, e) => ExitApp());
            menu.Opening += (s, e) => auto.Checked = autostart;   // reflect current state
            ni.ContextMenuStrip = menu;
            ni.DoubleClick += (s, e) => ShowSettings();
            ni.Visible = true;
            return ni;
        }

        // Keep one icon present even before the first reading (mouse asleep / not
        // found yet) so the menu stays reachable; replaced once a mouse reports.
        void EnsurePlaceholder()
        {
            if (icons.Keys.Any(k => k != PlaceholderKey)) { RemovePlaceholder(); return; }
            if (icons.ContainsKey(PlaceholderKey)) return;
            var ni = NewTrayIcon();
            ni.Icon = MakeIcon(0, "none", 0);
            ni.Text = "Mouse battery: waiting for a reading";
            icons[PlaceholderKey] = ni;
        }
        void RemovePlaceholder()
        {
            NotifyIcon ni;
            if (!icons.TryGetValue(PlaceholderKey, out ni)) return;
            icons.Remove(PlaceholderKey);
            ni.Visible = false;
            if (ni.Icon != null) Native.DestroyIcon(ni.Icon.Handle);
            ni.Dispose();
        }

        void UpdateIcon(string name, int pct, string status, bool stale)
        {
            NotifyIcon ni;
            if (!icons.TryGetValue(name, out ni)) { ni = NewTrayIcon(); icons[name] = ni; }
            iconState[name] = new IconState { Pct = pct, Status = status };
            RenderIcon(ni, pct, status);
            string tip = name + " - " + pct + "% (" + status + ")" + (stale ? " - last known" : "");
            if (tip.Length > 63) tip = tip.Substring(0, 63);
            ni.Text = tip;
        }
        void RenderIcon(NotifyIcon ni, int pct, string status)
        {
            Icon old = ni.Icon;
            ni.Icon = MakeIcon(pct, status, frame);
            if (old != null) { Native.DestroyIcon(old.Handle); old.Dispose(); }
        }
        // Re-draw only the icons whose state animates; steady healthy levels stay static.
        void AnimTick()
        {
            frame++;
            foreach (var kv in icons)
            {
                IconState st;
                if (iconState.TryGetValue(kv.Key, out st) && IsAnimated(st.Status, st.Pct))
                    RenderIcon(kv.Value, st.Pct, st.Status);
            }
        }
        bool IsAnimated(string status, int pct)
        {
            return status == "charging" || status == "full" || (status == "discharging" && pct < (int)LowRearm);
        }
        static Color LevelColor(int pct, string status)
        {
            if (status == "none") return Color.FromArgb(127, 140, 141);
            if (status == "full") return Color.FromArgb(39, 174, 96);
            if (status == "charging") return Color.FromArgb(41, 128, 185);
            if (pct >= 60) return Color.FromArgb(46, 204, 113);
            if (pct >= 30) return Color.FromArgb(243, 156, 18);
            return Color.FromArgb(231, 76, 60);
        }
        static Color Lerp(Color a, Color b, double t)
        {
            if (t < 0) t = 0; if (t > 1) t = 1;
            return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }
        static GraphicsPath RoundRect(RectangleF r, float rad)
        {
            var p = new GraphicsPath(); float d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure(); return p;
        }
        static double Triangle(int frame, int period)   // 0 -> 1 -> 0 over `period` frames
        {
            int ph = ((frame % period) + period) % period;
            double t = ph / (double)period;
            return t < 0.5 ? t * 2 : (1 - t) * 2;
        }
        // A rounded battery: body + terminal nub, fill height = charge %, colour by
        // level. Charging tops the fill up in a rising wave; low/full states pulse.
        Icon MakeIcon(int pct, string status, int frame)
        {
            var bmp = new Bitmap(32, 32);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                g.Clear(Color.Transparent);

                Color col = LevelColor(pct, status);
                bool pulseLow = status == "discharging" && pct < (int)LowRearm;
                double pulse = 0.5 + 0.5 * Math.Sin(frame / 8.0 * 2 * Math.PI);
                Color outline = col;
                if (pulseLow) outline = Lerp(col, Color.White, pulse * 0.55);
                else if (status == "full") outline = Lerp(col, Color.White, pulse * 0.35);

                var body = new RectangleF(6.5f, 7f, 19f, 22f);
                using (var nb = new SolidBrush(col)) g.FillRectangle(nb, 13f, 3.5f, 6f, 4f);   // terminal nub

                // fill level (charging tops it up toward full in a rising triangle wave)
                double frac = status == "none" ? 0 : pct / 100.0;
                if (status == "charging") frac = Math.Min(1.0, frac + (1.0 - frac) * Triangle(frame, 16) * 0.4);
                if (frac > 0)
                {
                    const float inset = 2.5f;
                    var inner = new RectangleF(body.X + inset, body.Y + inset, body.Width - 2 * inset, body.Height - 2 * inset);
                    float fh = (float)(inner.Height * frac);
                    var fillR = new RectangleF(inner.X, inner.Bottom - fh, inner.Width, fh);
                    using (var path = RoundRect(fillR, Math.Min(2.5f, fh / 2f)))
                    using (var fb = new SolidBrush(Color.FromArgb(220, col))) g.FillPath(fb, path);
                }
                if (status == "charging")   // rising highlight band
                {
                    float top = body.Y + 2.5f, bot = body.Bottom - 2.5f;
                    float y = bot - (float)((bot - top) * (frame % 16) / 16.0);
                    using (var hb = new SolidBrush(Color.FromArgb(70, 255, 255, 255)))
                        g.FillRectangle(hb, body.X + 2.5f, y - 1.5f, body.Width - 5f, 3f);
                }
                using (var path = RoundRect(body, 4f))
                using (var pen = new Pen(outline, 2f)) g.DrawPath(pen, path);

                string label = status == "none" ? "?" : (pct >= 100 ? "F" : pct.ToString());
                int fpx = label.Length >= 2 ? 14 : 17;
                using (var font = new Font("Segoe UI", fpx, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                {
                    var box = new RectangleF(0, 5, 32, 27);
                    using (var halo = new SolidBrush(Color.FromArgb(190, 0, 0, 0)))
                    {
                        g.DrawString(label, font, halo, new RectangleF(box.X + 1, box.Y + 1, box.Width, box.Height), sf);
                        g.DrawString(label, font, halo, new RectangleF(box.X - 1, box.Y + 1, box.Width, box.Height), sf);
                    }
                    g.DrawString(label, font, Brushes.White, box, sf);
                }
            }
            IntPtr hicon = bmp.GetHicon();
            bmp.Dispose();
            return Icon.FromHandle(hicon);
        }
        void Toast(string title, string text) { ToastOn(null, title, text); }
        // Show the balloon on the named mouse's own icon so that, when several mice
        // nudge in the same pass, one does not overwrite another's pending balloon.
        void ToastOn(string name, string title, string text)
        {
            NotifyIcon ni = null;
            if (name != null) icons.TryGetValue(name, out ni);
            if (ni == null) ni = icons.Values.FirstOrDefault();
            if (ni == null) return;
            ni.BalloonTipIcon = ToolTipIcon.Info; ni.BalloonTipTitle = title; ni.BalloonTipText = text;
            try { ni.ShowBalloonTip(5000); } catch { }
        }
        void ExitApp()
        {
            if (timer != null) timer.Stop();
            if (anim != null) anim.Stop();
            if (nudgeTimer != null) nudgeTimer.Stop();
            SystemEvents.SessionSwitch -= OnSessionSwitch;
            foreach (var ni in icons.Values) { ni.Visible = false; if (ni.Icon != null) Native.DestroyIcon(ni.Icon.Handle); ni.Dispose(); }
            ExitThread();
        }

        // --- autostart (HKCU Run key; re-points to the current exe on launch) -
        void ReconcileAutostart()
        {
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    string want = "\"" + Application.ExecutablePath + "\"";
                    string cur = k.GetValue(RunName) as string;
                    if (autostart) { if (cur != want) { k.SetValue(RunName, want); Util.Log("autostart -> " + want); } }
                    else if (cur != null) { k.DeleteValue(RunName, false); Util.Log("autostart off"); }
                }
            }
            catch (Exception e) { Util.Log("autostart failed: " + e.Message); }
        }
        void ToggleAutostart() { autostart = !autostart; SaveSettings(); ReconcileAutostart(); }

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
                if (o.ContainsKey("Autostart")) autostart = Convert.ToBoolean(o["Autostart"]);
                if (o.ContainsKey("NudgeLowStep")) NudgeLowStep = Convert.ToInt32(o["NudgeLowStep"]);
                if (o.ContainsKey("NudgeRearmStep")) NudgeRearmStep = Convert.ToInt32(o["NudgeRearmStep"]);
                if (o.ContainsKey("NudgeCritSecs")) NudgeCritSecs = Convert.ToInt32(o["NudgeCritSecs"]);
                if (o.ContainsKey("NudgeFullMins")) NudgeFullMins = Convert.ToInt32(o["NudgeFullMins"]);
            }
            catch { }
        }
        void SaveSettings()
        {
            var ic = CultureInfo.InvariantCulture;
            try
            {
                File.WriteAllText(Paths.Settings, "{\"FullMin\":" + FullMin.ToString(ic) + ",\"LowThresh\":" + LowThresh.ToString(ic) +
                    ",\"LowRearm\":" + LowRearm.ToString(ic) + ",\"Autostart\":" + (autostart ? "true" : "false") +
                    ",\"NudgeLowStep\":" + NudgeLowStep + ",\"NudgeRearmStep\":" + NudgeRearmStep +
                    ",\"NudgeCritSecs\":" + NudgeCritSecs + ",\"NudgeFullMins\":" + NudgeFullMins + "}");
            }
            catch { }
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
                f.Text = "Mouse Battery - notifications";
                f.ClientSize = new Size(320, 300);
                f.FormBorderStyle = FormBorderStyle.FixedDialog; f.StartPosition = FormStartPosition.CenterScreen;
                f.MaximizeBox = false; f.MinimizeBox = false; f.TopMost = true; f.ShowInTaskbar = false;
                var nLow = AddNud(f, "Low battery warning at (%):", 16, 1, 50, (int)LowThresh);
                var nRe = AddNud(f, "Re-arm low warning above (%):", 48, 1, 60, (int)LowRearm);
                var nFull = AddNud(f, "Full charge at (%):", 80, 50, 100, (int)FullMin);
                var nSl = AddNud(f, "Nudge every N% drop below low:", 112, 1, 20, NudgeLowStep);
                var nSr = AddNud(f, "Nudge every N% drop below re-arm:", 144, 1, 20, NudgeRearmStep);
                var nCs = AddNud(f, "Critical nudge every (sec):", 176, 5, 600, NudgeCritSecs);
                var nFm = AddNud(f, "Full-charge nudge every (min):", 208, 1, 120, NudgeFullMins);
                var ok = new Button { Text = "Save", Bounds = new Rectangle(145, 256, 75, 28), DialogResult = DialogResult.OK };
                var cn = new Button { Text = "Cancel", Bounds = new Rectangle(228, 256, 75, 28), DialogResult = DialogResult.Cancel };
                f.Controls.Add(ok); f.Controls.Add(cn); f.AcceptButton = ok; f.CancelButton = cn;
                if (f.ShowDialog() == DialogResult.OK)
                {
                    LowThresh = (double)nLow.Value; LowRearm = (double)nRe.Value; FullMin = (double)nFull.Value;
                    NudgeLowStep = (int)nSl.Value; NudgeRearmStep = (int)nSr.Value;
                    NudgeCritSecs = (int)nCs.Value; NudgeFullMins = (int)nFm.Value;
                    SaveSettings();
                    Util.Log("settings updated: low=" + LowThresh + " rearm=" + LowRearm + " full=" + FullMin +
                        " step=" + NudgeLowStep + "/" + NudgeRearmStep + " crit=" + NudgeCritSecs + "s fullEvery=" + NudgeFullMins + "m");
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
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);

        // Locked <=> the interactive input desktop is the secure (Winlogon) desktop,
        // which a normal-integrity process cannot open. Used to seed the lock state
        // at startup (SessionSwitch keeps it live thereafter).
        public static bool IsLocked()
        {
            IntPtr d = OpenInputDesktop(0, false, 0x0100 /* DESKTOP_SWITCHDESKTOP */);
            if (d == IntPtr.Zero) return true;
            CloseDesktop(d); return false;
        }

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
