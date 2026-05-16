using System;
using System.Diagnostics;
using System.IO;
using System.Text;

class TriangleWrapper
{
    static string Quote(string s)
    {
        if (s == null) return "\"\"";
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    static string BuildArgs(string[] args)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < args.Length; ++i)
        {
            if (i != 0) sb.Append(' ');
            sb.Append(Quote(args[i]));
        }
        return sb.ToString();
    }

    static string FindRootArg(string[] args)
    {
        for (int i = args.Length - 1; i >= 0; --i)
        {
            if (!args[i].StartsWith("-")) return args[i].Trim('"');
        }
        return null;
    }

    static void CopyIfExists(string src, string dst)
    {
        try
        {
            if (File.Exists(src))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(dst));
                File.Copy(src, dst, true);
            }
        }
        catch (Exception ex)
        {
            File.AppendAllText(dst + ".copy_error.txt", ex.ToString());
        }
    }

    static void Main(string[] args)
    {
        string exeDir = AppDomain.CurrentDomain.BaseDirectory;
        string realTriangle = Path.Combine(exeDir, "triangle_real.exe");
        if (!File.Exists(realTriangle))
        {
            Console.Error.WriteLine("triangle_real.exe not found next to wrapper: " + realTriangle);
            Environment.Exit(127);
        }

        string root = FindRootArg(args);
        string captureDir = null;
        if (!String.IsNullOrEmpty(root))
        {
            string rootDir = Path.GetDirectoryName(root);
            string rootName = Path.GetFileName(root);
            if (String.IsNullOrEmpty(rootDir)) rootDir = Directory.GetCurrentDirectory();
            captureDir = Path.Combine(rootDir, "captured_femm_triangle");
            Directory.CreateDirectory(captureDir);
            File.WriteAllText(Path.Combine(captureDir, "triangle_args.txt"), BuildArgs(args) + Environment.NewLine);
            CopyIfExists(root + ".poly", Path.Combine(captureDir, rootName + ".poly"));
            CopyIfExists(root + ".pbc", Path.Combine(captureDir, rootName + ".pbc.before"));
        }

        var psi = new ProcessStartInfo();
        psi.FileName = realTriangle;
        psi.Arguments = BuildArgs(args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;

        int code;
        using (var p = Process.Start(psi))
        {
            p.WaitForExit();
            code = p.ExitCode;
        }

        if (!String.IsNullOrEmpty(root) && !String.IsNullOrEmpty(captureDir))
        {
            string rootName = Path.GetFileName(root);
            CopyIfExists(root + ".node", Path.Combine(captureDir, rootName + ".node"));
            CopyIfExists(root + ".ele", Path.Combine(captureDir, rootName + ".ele"));
            CopyIfExists(root + ".edge", Path.Combine(captureDir, rootName + ".edge"));
            CopyIfExists(root + ".pbc", Path.Combine(captureDir, rootName + ".pbc.after"));
            File.WriteAllText(Path.Combine(captureDir, "triangle_exit_code.txt"), code.ToString() + Environment.NewLine);
        }

        Environment.Exit(code);
    }
}
