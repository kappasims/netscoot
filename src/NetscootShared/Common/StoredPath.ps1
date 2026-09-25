# Netscoot.StoredPath: a relative path as written inside a file, rewritten in place when its target or its file moves.
# Add-Type in C# 5 so every engine module can name the type and Windows PowerShell 5.1 can compile it.

if (-not ('Netscoot.StoredPath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Netscoot
{
    public abstract class StoredPath
    {
        public string File { get; private set; }
        public string Raw { get; private set; }
        public string Target { get; private set; }

        protected StoredPath(string file, string raw, string target)
        {
            File = file;
            Raw = raw;
            Target = target;
        }

        // An attribute value in an MSBuild file, e.g. ProjectReference Include or Import Project.
        public static StoredPath InAttribute(string file, string attribute, string raw, string target)
        {
            return new AttributePath(file, attribute, raw, target, Path.DirectorySeparatorChar);
        }

        // A Project Path attribute in a .slnx, which always uses forward slashes.
        public static StoredPath InSlnxEntry(string file, string raw, string target)
        {
            return new AttributePath(file, "Path", raw, target, '/');
        }

        // A quoted project path on a .sln Project(...) line.
        public static StoredPath InSolutionEntry(string file, string raw, string target)
        {
            return new SolutionEntryPath(file, raw, target);
        }

        // The path string of a PowerShell dot-source, call or Import-Module.
        public static StoredPath InScript(string file, string raw, string target)
        {
            return new ScriptPath(file, raw, target);
        }

        public string RawPointingAt(string target)
        {
            return Format(RelativePath(Path.GetDirectoryName(File), target));
        }

        public string RawFollowing(string newFile)
        {
            return Format(RelativePath(Path.GetDirectoryName(newFile), Target));
        }

        public bool PointAt(string target)
        {
            return Rewrite(File, RawPointingAt(target));
        }

        public bool FollowFile(string newFile)
        {
            return Rewrite(newFile, RawFollowing(newFile));
        }

        protected abstract string Format(string relative);

        protected abstract string Token(string raw, char quote);

        protected virtual char[] Quotes
        {
            get { return new char[] { '"' }; }
        }

        protected virtual char DefaultSeparator
        {
            get { return Path.DirectorySeparatorChar; }
        }

        protected string Styled(string path)
        {
            bool slash = Raw.IndexOf('/') >= 0;
            bool backslash = Raw.IndexOf('\\') >= 0;
            if (slash && !backslash) { return path.Replace('\\', '/'); }
            if (backslash && !slash) { return path.Replace('/', '\\'); }
            if (!slash && !backslash) { return path.Replace('\\', DefaultSeparator).Replace('/', DefaultSeparator); }
            return path;
        }

        private bool Rewrite(string file, string newRaw)
        {
            byte[] bytes = System.IO.File.ReadAllBytes(file);
            bool bom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
            string text = System.IO.File.ReadAllText(file);
            bool changed = false;
            foreach (char q in Quotes)
            {
                string oldToken = Token(Raw, q);
                if (text.IndexOf(oldToken, StringComparison.Ordinal) >= 0)
                {
                    text = text.Replace(oldToken, Token(newRaw, q));
                    changed = true;
                }
            }
            if (changed) { System.IO.File.WriteAllText(file, text, new UTF8Encoding(bom)); }
            return changed;
        }

        private static string RelativePath(string fromDir, string to)
        {
            char sep = Path.DirectorySeparatorChar;
            StringComparison cmp = sep == '\\' ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            char[] seps = new char[] { '\\', '/' };
            string[] from = fromDir.Split(seps, StringSplitOptions.RemoveEmptyEntries);
            string[] dest = to.Split(seps, StringSplitOptions.RemoveEmptyEntries);
            int common = 0;
            while (common < from.Length && common < dest.Length && string.Equals(from[common], dest[common], cmp)) { common++; }
            if (common == 0 && sep == '\\') { return to; }
            List<string> parts = new List<string>();
            for (int i = common; i < from.Length; i++) { parts.Add(".."); }
            for (int i = common; i < dest.Length; i++) { parts.Add(dest[i]); }
            if (parts.Count == 0) { return "."; }
            return string.Join(sep.ToString(), parts.ToArray());
        }
    }

    public sealed class AttributePath : StoredPath
    {
        private const string ThisFileDirectory = "$(MSBuildThisFileDirectory)";

        private readonly char defaultSeparator;

        public string Attribute { get; private set; }

        internal AttributePath(string file, string attribute, string raw, string target, char separator) : base(file, raw, target)
        {
            Attribute = attribute;
            defaultSeparator = separator;
        }

        protected override char DefaultSeparator
        {
            get { return defaultSeparator; }
        }

        protected override char[] Quotes
        {
            get { return new char[] { '"', '\'' }; }
        }

        protected override string Format(string relative)
        {
            string styled = Styled(relative);
            if (Raw.StartsWith(ThisFileDirectory, StringComparison.OrdinalIgnoreCase)) { return ThisFileDirectory + styled; }
            return styled;
        }

        protected override string Token(string raw, char quote)
        {
            return Attribute + "=" + quote + raw + quote;
        }
    }

    public sealed class SolutionEntryPath : StoredPath
    {
        internal SolutionEntryPath(string file, string raw, string target) : base(file, raw, target) { }

        protected override char DefaultSeparator
        {
            get { return '\\'; }
        }

        protected override string Format(string relative)
        {
            return Styled(relative);
        }

        protected override string Token(string raw, char quote)
        {
            return quote + raw + quote;
        }
    }

    public sealed class ScriptPath : StoredPath
    {
        private const string ScriptRoot = "$PSScriptRoot";

        internal ScriptPath(string file, string raw, string target) : base(file, raw, target) { }

        protected override string Format(string relative)
        {
            string styled = Styled(relative);
            string sep = Styled(Path.DirectorySeparatorChar.ToString());
            if (Raw.StartsWith(ScriptRoot, StringComparison.OrdinalIgnoreCase)) { return ScriptRoot + sep + styled; }
            if (styled.StartsWith("." + sep) || styled.StartsWith(".." + sep)) { return styled; }
            return "." + sep + styled;
        }

        protected override string Token(string raw, char quote)
        {
            return raw;
        }
    }
}
'@
}
