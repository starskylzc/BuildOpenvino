using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Text;
using System.Text.Json;

/// <summary>
/// ApiMinWin
/// ---------
/// Infers the minimum Windows build required by a native PE file by:
/// 1) parsing the PE import table (incl. delay-load imports), and
/// 2) mapping imported Win32 APIs to their SupportedOSPlatform("windows...") metadata
///    from Windows.Win32.winmd (from the Microsoft.Windows.SDK.Win32Metadata NuGet package).
///
/// Modes:
///   A) Analyze a PE file:
///        ApiMinWin --winmd <Windows.Win32.winmd> --pe <path-to-dll-or-exe> [--json]
///      Output:
///        - default: human-readable
///        - --json : a JSON object containing RequiredMinBuild/Reason etc.
///
///   B) Lookup mode (back-compat): read "dll,func" lines from stdin and output
///      "dll,func,minBuild,reason".
///        ApiMinWin <Windows.Win32.winmd>
///
/// Notes:
/// - If the --winmd argument points to a .txt file, the first non-empty line is treated
///   as the actual .winmd path (fixes a common workflow wiring error).
/// </summary>
internal static class Program
{
    private const string DllImportAttr = "System.Runtime.InteropServices.DllImportAttribute";
    private const string SupportedOsPlatformAttr = "System.Runtime.Versioning.SupportedOSPlatformAttribute";

    private sealed record ApiInfo(int MinBuild, string Reason);

    private sealed record AnalyzeResult(
        string PePath,
        int RequiredMinBuild,
        string RequiredMinReason,
        int ImportCount,
        int MappedImportCount,
        int UnmappedImportCount,
        bool Is64Bit
    );

    private readonly record struct ImportSymbol(string Module, string Symbol);

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0 || args.Any(a => a is "-h" or "--help" or "/?"))
            {
                PrintUsage();
                return args.Length == 0 ? 2 : 0;
            }

            // Simple option parsing.
            var winmdArg = GetOption(args, "--winmd");
            var peArg = GetOption(args, "--pe");
            var json = args.Any(a => a.Equals("--json", StringComparison.OrdinalIgnoreCase));

            // Back-compat: positional winmd
            if (winmdArg == null)
            {
                winmdArg = args[0];
            }

            var winmdPath = ResolveWinmdPath(winmdArg);
            if (!File.Exists(winmdPath))
            {
                Console.Error.WriteLine($"winmd not found: {winmdPath}");
                return 2;
            }

            var map = BuildMap(winmdPath);
            Console.Error.WriteLine($"[ApiMinWin] map size = {map.Count}");

            // Mode A: analyze a PE.
            if (!string.IsNullOrWhiteSpace(peArg))
            {
                if (!File.Exists(peArg))
                {
                    Console.Error.WriteLine($"pe not found: {peArg}");
                    return 2;
                }

                var result = AnalyzePe(peArg, map);
                if (json)
                {
                    Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions
                    {
                        WriteIndented = false,
                        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
                    }));
                }
                else
                {
                    Console.WriteLine($"PE: {result.PePath}");
                    Console.WriteLine($"Bitness: {(result.Is64Bit ? "x64" : "x86")}");
                    Console.WriteLine($"Imports: {result.ImportCount} (mapped {result.MappedImportCount}, unmapped {result.UnmappedImportCount})");
                    Console.WriteLine($"RequiredMinBuild: {result.RequiredMinBuild}");
                    Console.WriteLine($"Reason: {result.RequiredMinReason}");
                }

                return 0;
            }

            // Mode B (stdin lookup):
            // Output header
            Console.WriteLine("dll,func,minBuild,reason");

            string? line;
            while ((line = Console.ReadLine()) != null)
            {
                line = line.Trim();
                if (line.Length == 0) continue;

                var parts = line.Split(',', 2);
                if (parts.Length < 2) continue;

                var dll = parts[0].Trim();
                var func = parts[1].Trim();

                var (minBuild, reason) = Lookup(map, dll, func);
                Console.WriteLine($"{NormalizeModuleName(dll)},{EscapeCsv(func)},{minBuild},{EscapeCsv(reason)}");
            }

            return 0;
        }
        catch (BadImageFormatException ex)
        {
            Console.Error.WriteLine($"Bad image format: {ex.Message}");
            return 3;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            return 1;
        }
    }

    private static void PrintUsage()
    {
        Console.Error.WriteLine(
            "Usage:\n" +
            "  Analyze a PE (recommended):\n" +
            "    ApiMinWin --winmd <Windows.Win32.winmd> --pe <path-to-dll-or-exe> [--json]\n\n" +
            "  Lookup mode (stdin):\n" +
            "    ApiMinWin <Windows.Win32.winmd>\n" +
            "    (then pipe lines of: dll,func ; outputs: dll,func,minBuild,reason)\n\n" +
            "Notes:\n" +
            "  - If --winmd points to a .txt file, the first non-empty line is treated as the real .winmd path.\n"
        );
    }

    private static string? GetOption(string[] args, string name)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (!args[i].Equals(name, StringComparison.OrdinalIgnoreCase)) continue;
            if (i + 1 < args.Length) return args[i + 1];
            return null;
        }

        return null;
    }

    private static string ResolveWinmdPath(string path)
    {
        var p = path.Trim();
        if (p.EndsWith(".txt", StringComparison.OrdinalIgnoreCase) && File.Exists(p))
        {
            foreach (var line in File.ReadLines(p))
            {
                var t = line.Trim();
                if (t.Length == 0) continue;
                return t;
            }
        }

        return p;
    }

    private static string EscapeCsv(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        if (s.Contains(',') || s.Contains('"') || s.Contains('\n') || s.Contains('\r'))
        {
            return "\"" + s.Replace("\"", "\"\"") + "\"";
        }
        return s;
    }

    private static (int minBuild, string reason) Lookup(Dictionary<string, ApiInfo> map, string dll, string func)
    {
        dll = NormalizeModuleName(dll);
        var (minBuild, reason) = LookupInternal(map, dll, func);
        if (minBuild != 0 || !string.IsNullOrEmpty(reason))
            return (minBuild, reason);

        // Try A/W suffix strip.
        var altFunc = TryStripAnsiUnicodeSuffix(func);
        if (altFunc != null)
        {
            (minBuild, reason) = LookupInternal(map, dll, altFunc);
            if (minBuild != 0 || !string.IsNullOrEmpty(reason))
                return (minBuild, reason);
        }

        return (0, "");
    }

    private static (int minBuild, string reason) LookupInternal(Dictionary<string, ApiInfo> map, string dll, string func)
    {
        // Try with dll as-is
        var key = dll + "!" + func;
        if (map.TryGetValue(key, out var info))
            return (info.MinBuild, info.Reason);

        // Try without extension
        if (dll.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
        {
            var noExt = dll[..^4];
            key = noExt + "!" + func;
            if (map.TryGetValue(key, out info))
                return (info.MinBuild, info.Reason);
        }
        else
        {
            var withExt = dll + ".dll";
            key = withExt + "!" + func;
            if (map.TryGetValue(key, out info))
                return (info.MinBuild, info.Reason);
        }

        return (0, "");
    }

    private static string? TryStripAnsiUnicodeSuffix(string func)
    {
        if (func.Length <= 1) return null;
        var last = func[^1];
        if (last is 'A' or 'W')
            return func[..^1];
        return null;
    }

    private static string NormalizeModuleName(string dll)
    {
        dll = dll.Trim().Trim('"').Trim().ToLowerInvariant();
        return dll;
    }

    private static AnalyzeResult AnalyzePe(string pePath, Dictionary<string, ApiInfo> map)
    {
        using var fs = File.OpenRead(pePath);
        using var pe = new PEReader(fs);
        var headers = pe.PEHeaders;
        var is64 = headers.PEHeader != null && headers.PEHeader.Magic == PEMagic.PE32Plus;

        var bytes = ReadAllBytes(fs);

        var imports = new List<ImportSymbol>(capacity: 2048);
        imports.AddRange(ReadImportTable(bytes, headers, is64));
        imports.AddRange(ReadDelayImportTable(bytes, headers, is64));

        // Dedup, keep stable ordering.
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var unique = new List<ImportSymbol>(imports.Count);
        foreach (var s in imports)
        {
            var k = NormalizeModuleName(s.Module) + "!" + s.Symbol;
            if (seen.Add(k)) unique.Add(new ImportSymbol(NormalizeModuleName(s.Module), s.Symbol));
        }

        int maxBuild = 0;
        string maxReason = "";

        int mapped = 0;
        foreach (var sym in unique)
        {
            // Skip ordinals
            if (sym.Symbol.StartsWith('#'))
                continue;

            var (b, reason) = Lookup(map, sym.Module, sym.Symbol);
            if (b != 0) mapped++;

            if (b > maxBuild)
            {
                maxBuild = b;
                maxReason = reason;
            }
        }

        return new AnalyzeResult(
            PePath: pePath,
            RequiredMinBuild: maxBuild,
            RequiredMinReason: maxReason,
            ImportCount: unique.Count,
            MappedImportCount: mapped,
            UnmappedImportCount: Math.Max(0, unique.Count - mapped),
            Is64Bit: is64
        );
    }

    private static byte[] ReadAllBytes(FileStream fs)
    {
        // PEReader advanced the stream; reset.
        fs.Position = 0;
        using var ms = new MemoryStream((int)Math.Min(int.MaxValue, fs.Length));
        fs.CopyTo(ms);
        return ms.ToArray();
    }

    private static IEnumerable<ImportSymbol> ReadImportTable(byte[] bytes, PEHeaders headers, bool is64)
    {
        var peh = headers.PEHeader;
        if (peh == null) yield break;

        var dir = peh.ImportTableDirectory;
        if (dir.RelativeVirtualAddress == 0 || dir.Size == 0) yield break;

        int offset = RvaToOffset(headers, dir.RelativeVirtualAddress);
        const int descSize = 20; // IMAGE_IMPORT_DESCRIPTOR

        while (offset + descSize <= bytes.Length)
        {
            uint originalFirstThunk = ReadU32(bytes, offset + 0);
            uint timeDateStamp = ReadU32(bytes, offset + 4);
            uint forwarderChain = ReadU32(bytes, offset + 8);
            uint nameRva = ReadU32(bytes, offset + 12);
            uint firstThunk = ReadU32(bytes, offset + 16);

            if (originalFirstThunk == 0 && timeDateStamp == 0 && forwarderChain == 0 && nameRva == 0 && firstThunk == 0)
                yield break;

            string dllName = ReadAsciiZ(bytes, RvaToOffset(headers, (int)nameRva));

            uint thunkRva = originalFirstThunk != 0 ? originalFirstThunk : firstThunk;
            foreach (var sym in ReadThunkArray(bytes, headers, is64, dllName, thunkRva))
                yield return sym;

            offset += descSize;
        }
    }

    private static IEnumerable<ImportSymbol> ReadDelayImportTable(byte[] bytes, PEHeaders headers, bool is64)
    {
        var peh = headers.PEHeader;
        if (peh == null) yield break;

        var dir = peh.DelayImportTableDirectory;
        if (dir.RelativeVirtualAddress == 0 || dir.Size == 0) yield break;

        // IMAGE_DELAYLOAD_DESCRIPTOR is 32 bytes.
        int offset = RvaToOffset(headers, dir.RelativeVirtualAddress);
        const int descSize = 32;

        while (offset + descSize <= bytes.Length)
        {
            uint attributes = ReadU32(bytes, offset + 0);
            uint nameRva = ReadU32(bytes, offset + 4);
            uint moduleHandleRva = ReadU32(bytes, offset + 8);
            uint delayIatRva = ReadU32(bytes, offset + 12);
            uint delayIntRva = ReadU32(bytes, offset + 16);
            uint boundIatRva = ReadU32(bytes, offset + 20);
            uint unloadIatRva = ReadU32(bytes, offset + 24);
            uint timeDateStamp = ReadU32(bytes, offset + 28);

            if (attributes == 0 && nameRva == 0 && moduleHandleRva == 0 && delayIatRva == 0 && delayIntRva == 0 && boundIatRva == 0 && unloadIatRva == 0 && timeDateStamp == 0)
                yield break;

            string dllName = ReadAsciiZ(bytes, RvaToOffset(headers, (int)nameRva));

            // In delay-load, INT is DelayImportNameTable (import names), similar thunk array.
            if (delayIntRva != 0)
            {
                foreach (var sym in ReadThunkArray(bytes, headers, is64, dllName, delayIntRva))
                    yield return sym;
            }

            offset += descSize;
        }
    }

    private static IEnumerable<ImportSymbol> ReadThunkArray(byte[] bytes, PEHeaders headers, bool is64, string dllName, uint thunkRva)
    {
        if (thunkRva == 0) yield break;

        int offset = RvaToOffset(headers, (int)thunkRva);
        int step = is64 ? 8 : 4;

        while (offset + step <= bytes.Length)
        {
            ulong thunk = is64 ? ReadU64(bytes, offset) : ReadU32(bytes, offset);
            if (thunk == 0) yield break;

            bool isOrdinal = is64
                ? (thunk & 0x8000_0000_0000_0000UL) != 0
                : (thunk & 0x8000_0000UL) != 0;

            if (isOrdinal)
            {
                ushort ord = (ushort)(thunk & 0xFFFF);
                yield return new ImportSymbol(dllName, "#" + ord);
            }
            else
            {
                uint ibnRva = is64 ? (uint)(thunk & 0x7FFF_FFFF_FFFF_FFFFUL) : (uint)(thunk & 0x7FFF_FFFFUL);
                int ibnOff = RvaToOffset(headers, (int)ibnRva);
                if (ibnOff + 2 < bytes.Length)
                {
                    // IMAGE_IMPORT_BY_NAME: ushort Hint; char Name[]
                    string func = ReadAsciiZ(bytes, ibnOff + 2);
                    if (!string.IsNullOrEmpty(func))
                        yield return new ImportSymbol(dllName, func);
                }
            }

            offset += step;
        }
    }

    private static int RvaToOffset(PEHeaders headers, int rva)
    {
        // For RVAs that fall into the headers, PointerToRawData is 0.
        foreach (var sec in headers.SectionHeaders)
        {
            int start = sec.VirtualAddress;
            int size = Math.Max(sec.VirtualSize, sec.SizeOfRawData);
            int end = start + size;
            if (rva >= start && rva < end)
            {
                return (rva - start) + sec.PointerToRawData;
            }
        }

        return rva;
    }

    private static uint ReadU32(byte[] bytes, int offset)
    {
        return BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
    }

    private static ulong ReadU64(byte[] bytes, int offset)
    {
        return BinaryPrimitives.ReadUInt64LittleEndian(bytes.AsSpan(offset, 8));
    }

    private static string ReadAsciiZ(byte[] bytes, int offset)
    {
        if (offset < 0 || offset >= bytes.Length) return string.Empty;
        int end = offset;
        while (end < bytes.Length && bytes[end] != 0) end++;
        if (end <= offset) return string.Empty;
        return Encoding.ASCII.GetString(bytes, offset, end - offset);
    }

    private static Dictionary<string, ApiInfo> BuildMap(string winmdPath)
    {
        using var fs = File.OpenRead(winmdPath);
        using var pe = new PEReader(fs);
        var md = pe.GetMetadataReader();

        var map = new Dictionary<string, ApiInfo>(StringComparer.OrdinalIgnoreCase);

        foreach (var typeHandle in md.TypeDefinitions)
        {
            var type = md.GetTypeDefinition(typeHandle);

            foreach (var methodHandle in type.GetMethods())
            {
                var method = md.GetMethodDefinition(methodHandle);

                string? dllName = null;
                string? entryPoint = null;
                int minBuild = 0;
                string minReason = "";

                foreach (var caHandle in method.GetCustomAttributes())
                {
                    var ca = md.GetCustomAttribute(caHandle);
                    var attrName = GetAttributeTypeFullName(md, ca);
                    if (attrName == null) continue;

                    if (attrName == DllImportAttr)
                    {
                        ReadDllImport(md, ca, out dllName, out entryPoint);
                    }
                    else if (attrName == SupportedOsPlatformAttr)
                    {
                        var plat = ReadSingleStringCtorArg(md, ca);
                        if (!string.IsNullOrWhiteSpace(plat))
                        {
                            var build = ExtractBuild(plat!);
                            if (build > minBuild)
                            {
                                minBuild = build;
                                minReason = plat!;
                            }
                        }
                    }
                }

                if (string.IsNullOrWhiteSpace(dllName)) continue;

                var ep = entryPoint ?? md.GetString(method.Name);
                if (string.IsNullOrWhiteSpace(ep)) continue;

                var dllNorm = NormalizeModuleName(dllName!);

                // Add both with and without .dll extension to reduce mismatches.
                foreach (var module in ModuleNameVariants(dllNorm))
                {
                    var key = module + "!" + ep;
                    if (!map.TryGetValue(key, out var existing) || minBuild > existing.MinBuild)
                    {
                        map[key] = new ApiInfo(minBuild, minReason);
                    }

                    // Also insert A/W stripped variants for convenience.
                    var alt = TryStripAnsiUnicodeSuffix(ep);
                    if (alt != null)
                    {
                        var keyAlt = module + "!" + alt;
                        if (!map.TryGetValue(keyAlt, out existing) || minBuild > existing.MinBuild)
                        {
                            map[keyAlt] = new ApiInfo(minBuild, minReason);
                        }
                    }
                }
            }
        }

        return map;
    }

    private static IEnumerable<string> ModuleNameVariants(string module)
    {
        module = NormalizeModuleName(module);
        yield return module;

        if (module.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
        {
            yield return module[..^4];
        }
        else
        {
            yield return module + ".dll";
        }
    }

    private static int ExtractBuild(string s)
    {
        // Typical strings look like: windows10.0.19041
        // We treat the first numeric segment >= 10000 as the build.
        var parts = s.Split('.', StringSplitOptions.RemoveEmptyEntries);
        foreach (var p in parts)
        {
            if (int.TryParse(p, out var v) && v >= 10000) return v;
        }
        return 0;
    }

    private static string? ReadSingleStringCtorArg(MetadataReader md, CustomAttribute ca)
    {
        var blob = md.GetBlobReader(ca.Value);
        if (blob.ReadUInt16() != 1) return null; // prolog
        return blob.ReadSerializedString();
    }

    private static void ReadDllImport(MetadataReader md, CustomAttribute ca, out string? dllName, out string? entryPoint)
    {
        dllName = null;
        entryPoint = null;

        var blob = md.GetBlobReader(ca.Value);
        if (blob.ReadUInt16() != 1) return; // prolog

        dllName = blob.ReadSerializedString();

        if (blob.Offset >= blob.Length) return;

        // Named arguments. Per ECMA-335: ushort NumNamed.
        ushort numNamed = blob.ReadUInt16();
        for (int i = 0; i < numNamed; i++)
        {
            byte kind = blob.ReadByte(); // 0x53 field, 0x54 property; we ignore.
            byte type = blob.ReadByte();
            string? name = blob.ReadSerializedString();
            object? val = ReadFixedArg(ref blob, type);

            if (name != null && name.Equals("EntryPoint", StringComparison.OrdinalIgnoreCase))
            {
                entryPoint = val as string;
            }
        }
    }

    private static object? ReadFixedArg(ref BlobReader blob, byte et)
    {
        // We only care about string fixed args.
        if (et == 0x0E)
        {
            return blob.ReadSerializedString();
        }

        SkipFixedArg(ref blob, et);
        return null;
    }

    private static void SkipFixedArg(ref BlobReader blob, byte et)
    {
        switch (et)
        {
            case 0x02: blob.ReadBoolean(); break;
            case 0x03: blob.ReadByte(); break;
            case 0x04: blob.ReadSByte(); break;
            case 0x05: blob.ReadInt16(); break;
            case 0x06: blob.ReadUInt16(); break;
            case 0x07: blob.ReadInt32(); break;
            case 0x08: blob.ReadUInt32(); break;
            case 0x09: blob.ReadInt64(); break;
            case 0x0A: blob.ReadUInt64(); break;
            case 0x0B: blob.ReadSingle(); break;
            case 0x0C: blob.ReadDouble(); break;
            case 0x0E: blob.ReadSerializedString(); break;
            default:
                // For uncommon encodings (e.g., Type), we bail out silently.
                break;
        }
    }

    private static string? GetAttributeTypeFullName(MetadataReader md, CustomAttribute ca)
    {
        EntityHandle ctor = ca.Constructor;
        StringHandle nameHandle;
        StringHandle nsHandle;

        if (ctor.Kind == HandleKind.MemberReference)
        {
            var mr = md.GetMemberReference((MemberReferenceHandle)ctor);
            var parent = mr.Parent;
            if (parent.Kind == HandleKind.TypeReference)
            {
                var tr = md.GetTypeReference((TypeReferenceHandle)parent);
                nameHandle = tr.Name;
                nsHandle = tr.Namespace;
            }
            else if (parent.Kind == HandleKind.TypeDefinition)
            {
                var td = md.GetTypeDefinition((TypeDefinitionHandle)parent);
                nameHandle = td.Name;
                nsHandle = td.Namespace;
            }
            else return null;
        }
        else if (ctor.Kind == HandleKind.MethodDefinition)
        {
            var mdh = md.GetMethodDefinition((MethodDefinitionHandle)ctor);
            var td = md.GetTypeDefinition(mdh.GetDeclaringType());
            nameHandle = td.Name;
            nsHandle = td.Namespace;
        }
        else return null;

        var name = md.GetString(nameHandle);
        var ns = md.GetString(nsHandle);
        return string.IsNullOrEmpty(ns) ? name : (ns + "." + name);
    }
}
