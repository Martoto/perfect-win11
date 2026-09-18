using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

internal static class Launcher
{
    // Windows CommandLineToArgvW / C-runtime quoting, not shell escaping.
    internal static string Quote(string value)
    {
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') result.Append('\\', slashes * 2 + 1);
            else result.Append('\\', slashes);
            result.Append(c);
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        return result.Append('"').ToString();
    }

    internal static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--version")
        {
            Console.WriteLine(Assembly.GetExecutingAssembly().GetName().Version.ToString(3));
            return 0;
        }
        if (args.Length == 1 && args[0] == "--help")
        {
            Console.WriteLine("Perfect Win11\nRun in a normal, non-administrator terminal.\n" +
                "perfect-win11 [-WhatIf] [-AppList <path-or-HTTPS-URL>]\n" +
                "perfect-win11 -Resume\nperfect-win11 -Reconfigure [-WhatIf]\n" +
                "perfect-win11 --restore-settings [-WhatIf]\nperfect-win11 --version\n" +
                "Installation only adds the tool. The wizard asks before applying changes.");
            return 0;
        }
        try
        {
            bool restore = args.Length > 0 && args[0] == "--restore-settings";
            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
                restore ? "Restore-Settings.ps1" : "Setup.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Application files are missing. Reinstall Perfect Win11.", script);
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            var command = new StringBuilder("-NoLogo -NoProfile -ExecutionPolicy Bypass -File ");
            command.Append(Quote(script));
            for (int i = restore ? 1 : 0; i < args.Length; i++) command.Append(' ').Append(Quote(args[i]));
            var start = new ProcessStartInfo(powershell, command.ToString());
            start.UseShellExecute = false;
            start.WorkingDirectory = Environment.CurrentDirectory;
            // Inherit the real console: ReadKey and the Ubuntu first-run prompt need it.
            using (Process child = Process.Start(start))
            {
                // Ctrl+C belongs to PowerShell. Keep waiting while its finally blocks release locks.
                ConsoleCancelEventHandler cancel = delegate(object sender, ConsoleCancelEventArgs e) { e.Cancel = true; };
                Console.CancelKeyPress += cancel;
                try { child.WaitForExit(); return child.ExitCode; }
                finally { Console.CancelKeyPress -= cancel; }
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Perfect Win11: " + error.Message);
            return 1;
        }
    }
}
