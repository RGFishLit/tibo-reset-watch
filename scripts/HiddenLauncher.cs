using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace TiboWatch {
    public static class HiddenLauncher {
        private static string Quote(string value) {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { result.Append('\\', slashes * 2 + 1).Append(c); }
                else { result.Append('\\', slashes).Append(c); }
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }

        public static int Main(string[] args) {
            string data = null;
            try {
                if (args.Length < 1 || args.Length > 2) { return 2; }
                data = Path.GetFullPath(args[0]);
                string action = args.Length == 2 ? args[1] : "Check";
                if (action != "Check" && action != "Status") { return 2; }
                string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "TiboWatch.ps1");
                var start = new ProcessStartInfo {
                    FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe"),
                    Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -Action " + action + " -DataDirectory " + Quote(data),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (var child = Process.Start(start)) {
                    child.BeginOutputReadLine();
                    child.BeginErrorReadLine();
                    child.WaitForExit();
                    return child.ExitCode;
                }
            } catch (Exception error) {
                try {
                    if (data != null && Directory.Exists(data)) {
                        File.AppendAllText(Path.Combine(data, "launcher-error.log"), DateTime.UtcNow.ToString("o") + " " + error.Message + Environment.NewLine);
                    }
                } catch { }
                return 1;
            }
        }
    }
}
