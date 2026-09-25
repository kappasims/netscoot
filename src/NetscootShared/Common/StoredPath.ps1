# Netscoot.StoredPath: a relative path as written inside a file, rewritten in place when its target or its file moves.
# Add-Type in C# 5 so every engine module can name the type and Windows PowerShell 5.1 can compile it.

if (-not ('Netscoot.StoredPath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

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

        protected virtual string Token(string raw, char quote)
        {
            return quote + raw + quote;
        }

        protected virtual char[] Quotes
        {
            get { return new char[] { '"' }; }
        }

        protected virtual string Replace(string text, string oldRaw, string newRaw)
        {
            foreach (char q in Quotes)
            {
                text = text.Replace(Token(oldRaw, q), Token(newRaw, q));
            }
            return text;
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
            EncodedText content = EncodedText.Read(file);
            string text = Replace(content.Text, Raw, newRaw);
            if (string.Equals(text, content.Text, StringComparison.Ordinal)) { return false; }
            content.Write(file, text);
            return true;
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

    // A file's text with the byte-order mark and encoding it was read in, so a rewrite keeps both.
    // BOM-less text that is not valid UTF-8 is a legacy code page, round-tripped byte for byte as Latin-1.
    internal sealed class EncodedText
    {
        private readonly byte[] bom;
        private readonly Encoding encoding;

        public string Text { get; private set; }

        private EncodedText(byte[] bom, Encoding encoding, string text)
        {
            this.bom = bom;
            this.encoding = encoding;
            Text = text;
        }

        public static EncodedText Read(string file)
        {
            byte[] bytes = System.IO.File.ReadAllBytes(file);
            Encoding[] withBom = new Encoding[]
            {
                new UTF32Encoding(false, true), new UTF32Encoding(true, true), new UTF8Encoding(true),
                new UnicodeEncoding(false, true), new UnicodeEncoding(true, true)
            };
            foreach (Encoding candidate in withBom)
            {
                byte[] preamble = candidate.GetPreamble();
                int matched = 0;
                while (matched < preamble.Length && matched < bytes.Length && bytes[matched] == preamble[matched]) { matched++; }
                if (matched == preamble.Length)
                {
                    return new EncodedText(preamble, candidate, candidate.GetString(bytes, preamble.Length, bytes.Length - preamble.Length));
                }
            }
            try
            {
                return new EncodedText(new byte[0], new UTF8Encoding(false), new UTF8Encoding(false, true).GetString(bytes));
            }
            catch (DecoderFallbackException)
            {
                Encoding latin1 = Encoding.GetEncoding(28591);
                return new EncodedText(new byte[0], latin1, latin1.GetString(bytes));
            }
        }

        public void Write(string file, string text)
        {
            byte[] body = encoding.GetBytes(text);
            byte[] all = new byte[bom.Length + body.Length];
            Buffer.BlockCopy(bom, 0, all, 0, bom.Length);
            Buffer.BlockCopy(body, 0, all, bom.Length, body.Length);
            System.IO.File.WriteAllBytes(file, all);
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

        // A script path may be quoted or bare, so it matches only as a whole token: not inside a
        // longer path such as ..\helpers.ps1 when the path is .\helpers.ps1.
        protected override string Replace(string text, string oldRaw, string newRaw)
        {
            string pattern = @"(?<![^\s'""(=,])" + Regex.Escape(oldRaw) + @"(?![^\s'""),;}|])";
            return Regex.Replace(text, pattern, newRaw.Replace("$", "$$"));
        }
    }
}
'@
}
