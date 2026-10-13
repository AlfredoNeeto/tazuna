// why: a double-click start for the same install.ps1 the README's one-liner runs, embedded here and
// run with Windows PowerShell in this console. scripts\build-installer.ps1 builds it with the csc.exe
// of .NET Framework 4, which every Windows has.
// invariant: C# 5 only - the language that compiler speaks.

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

static class TazunaSetup
{
    [DllImport("kernel32.dll")]
    static extern uint GetConsoleProcessList(uint[] processList, uint processCount);

    static int Main()
    {
        string script = Path.Combine(Path.GetTempPath(), "tazuna-install-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".ps1");
        int code = 1;

        try
        {
            using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("install.ps1"))
            using (FileStream target = File.Create(script))
            {
                source.CopyTo(target);
            }

            // why: the policy is set for this process only, as bin\tazuna.cmd does; nothing on the machine changes.
            string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo(powershell, "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"");
            start.UseShellExecute = false;

            using (Process process = Process.Start(start))
            {
                process.WaitForExit();
                code = process.ExitCode;
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Tazuna setup could not start: " + error.Message);
            code = 1;
        }
        finally
        {
            try { File.Delete(script); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        // why: a double-clicked console closes with its only process, taking the result with it before
        // anyone reads it. Started from a terminal, the shell shares the console and nothing waits.
        uint[] attached = new uint[2];
        if (GetConsoleProcessList(attached, 2) == 1)
        {
            Console.WriteLine();
            Console.Write("Press Enter to close.");
            Console.ReadLine();
        }

        return code;
    }
}
