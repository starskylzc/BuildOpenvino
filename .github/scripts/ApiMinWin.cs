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
/// 2) mapping imported APIs to SupportedOSPlatform info from Windows.Win32.winmd (Win32Metadata).
///
/// This tool can work in two modes:
///   A) Analyze PE directly:
///        ApiMinWin --winmd <path-to-Windows.Win32.winmd> --pe <path-to-dll> --json
///
///   B) Legacy stdin mapper (kept for compatibility):
///        echo "kernel32.dll,CreateFileW" | ApiMinWin --winmd <winmd>
/// </summary>
internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0 || args.Contains("-h") || args.Contains("--help"))
            {
                PrintHelp();
                return 0;
            }

            var winmdArg = GetArgValue(args, "--winmd") ?? GetArgValue(args, "-w");
            var pePath = GetArgValue(args, "--pe") ?? GetArgValue(args, "-p");
            var json = args.Contains("--json", StringComparer.OrdinalIgnoreCase);

            // Back-compat: allow passing winmd path as the first positional arg.
            winmdArg ??= args[0];

            var winmdPath = ResolveWinmdPath(winmdArg!);
            if (!File.Exists(winmdPath))
            {
                Console.Error.WriteLine($"ERROR: winmd not found: {winmdPath}");
                return 2;
            }

            var map = BuildApiMinBuildMap(winmdPath);

            if (!string.IsNullOrWhiteSpace(pePath))
            {
                if (!File.Exists(pePath))
                {
                    Console.Error.WriteLine($"ERROR: PE file not found: {pePath}");
                    return 3;
                }

                var result = AnalyzePe(pePath, map);

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
                    Console.WriteLine($"pe={result.PePath}");
                    Console.WriteLine($"is64Bit={result.Is64Bit}");
                    Console.WriteLine($"importCount={result.ImportCount}");
                    Console.WriteLine($"mappedImportCount={result.MappedImportCount}");
                    Console.WriteLine($"requiredMinBuild={result.RequiredMinBuild}");
                    Console.WriteLine($"requiredMinReason={result.RequiredMinReason}");
                }

                return 0;
            }

            // Legacy stdin mode: read `dll,func` per line and output `dll,func,minBuild,reason`.
            Console.WriteLine("dll,func,minBuild,reason");
            string? line;
            while ((line = Console.ReadLine()) != null)
            {
                line = line.Trim();
                if (line.Length == 0) continue;

                var parts = line.Split(',', 2);
                if (parts.Length != 2)
                {
                    Console.Error.WriteLine($"WARN: bad line (expected dll,func): {line}");
                    continue;
                }

                var dll = NormalizeModuleName(parts[0]);
                var func = parts[1].Trim();

                var (minBuild, reason) = LookupApi(map, dll, func);
                Console.WriteLine($"{dll},{func},{minBuild},{CsvEscape(reason)}");
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("FATAL: " + ex);
            return 1;
        }
    }

    private static void PrintHelp()
    {
        Console.WriteLine(
@"ApiMinWin - infer minimum Windows build based on imported Win32 APIs.

USAGE:
  # Analyze a PE (DLL/EXE)
  ApiMinWin --winmd <Windows.Win32.winmd> --pe <path-to-native-dll> [--json]

  # Legacy stdin mapping (dll,func per line)
  ApiMinWin --winmd <Windows.Win32.winmd>
    stdin:  kernel32.dll,CreateFileW
    stdout: dll,func,minBuild,reason

NOTES:
  - --winmd can also be a .txt file whose first non-empty line is the winmd path (back-compat).
  - minBuild is usually a Windows 10/11 build number (e.g. 19041, 22000). 0 means 'unknown/older than win10 metadata granularity'.");
    }

    private static string? GetArgValue(string[] args, string key)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], key, StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 < args.Length) return args[i + 1];
                return "";
            }
        }
        return null;
    }

    private static string ResolveWinmdPath(string input)
    {
        var p = input.Trim().Trim('"');
        if (p.EndsWith(".txt", StringComparison.OrdinalIgnoreCase) && File.Exists(p))
        {
            foreach (var line in File.ReadAllLines(p))
            {
                var l = line.Trim();
                if (l.Length == 0) continue;
                return l.Trim('"');
            }
            throw new InvalidOperationException($"winmd path file is empty: {p}");
        }

        return p;
    }

    // ---------- PE analysis mode ----------

    private sealed record AnalyzeResult(
        string PePath,
        bool Is64Bit,
        int ImportCount,
        int MappedImportCount,
        int RequiredMinBuild,
        string RequiredMinReason
    );

    private readonly record struct ImportSymbol(string Module, string Symbol);

    private static AnalyzeResult AnalyzePe(string pePath, Dictionary<string, WinApiInfo> apiMap)
    {
        var bytes = File.ReadAllBytes(pePath);

        using var pe = new PEReader(new MemoryStream(bytes, writable: false));
        var headers = pe.PEHeaders;
        var peHeader = headers.PEHeader ?? throw new InvalidOperationException("Missing PE header.");

        bool is64 = peHeader.Magic == PEMagic.PE32Plus;

        var imports = new List<ImportSymbol>();

        // Normal imports
        if (peHeader.ImportTableDirectory.RelativeVirtualAddress != 0)
        {
            imports.AddRange(ReadImportDescriptors(bytes, headers, peHeader.ImportTableDirectory.RelativeVirtualAddress, is64));
        }

        // Delay-load imports
        if (peHeader.DelayImportTableDirectory.RelativeVirtualAddress != 0)
        {
            imports.AddRange(ReadDelayImportDescriptors(bytes, headers, peHeader.DelayImportTableDirectory.RelativeVirtualAddress, is64));
        }

        int importCount = imports.Count;
        int mappedCount = 0;

        int maxBuild = 0;
        string maxReason = "";

        foreach (var imp in imports)
        {
            var dll = NormalizeModuleName(imp.Module);
            var func = imp.Symbol;

            if (func.StartsWith("#", StringComparison.Ordinal)) // ordinal import
                continue;

            var (minBuild, reason) = LookupApi(apiMap, dll, func);
            if (minBuild > 0 || reason.Length > 0) mappedCount++;

            if (minBuild > maxBuild)
            {
                maxBuild = minBuild;
                maxReason = reason;
            }
        }

        if (maxBuild == 0 && string.IsNullOrWhiteSpace(maxReason))
            maxReason = "UNKNOWN";

        return new AnalyzeResult(
            PePath: pePath,
            Is64Bit: is64,
            ImportCount: importCount,
            MappedImportCount: mappedCount,
            RequiredMinBuild: maxBuild,
            RequiredMinReason: maxReason
        );
    }

    // IMAGE_IMPORT_DESCRIPTOR is 20 bytes
    private static IEnumerable<ImportSymbol> ReadImportDescriptors(byte[] bytes, PEHeaders headers, int importDirRva, bool is64)
    {
        var results = new List<ImportSymbol>();
        int descOffset = RvaToOffset(headers, importDirRva);

        while (true)
        {
            // 5 * 4 bytes
            uint originalFirstThunk = ReadU32(bytes, descOffset + 0);
            uint timeDateStamp      = ReadU32(bytes, descOffset + 4);
            uint forwarderChain     = ReadU32(bytes, descOffset + 8);
            uint nameRva            = ReadU32(bytes, descOffset + 12);
            uint firstThunk         = ReadU32(bytes, descOffset + 16);

            if (originalFirstThunk == 0 && timeDateStamp == 0 && forwarderChain == 0 && nameRva == 0 && firstThunk == 0)
                break;

            string dllName = ReadAsciiZ(bytes, RvaToOffset(headers, (int)nameRva));

            uint thunkRva = originalFirstThunk != 0 ? originalFirstThunk : firstThunk;
            int thunkOffset = RvaToOffset(headers, (int)thunkRva);

            foreach (var sym in ReadThunkArray(bytes, headers, thunkOffset, is64, dllName))
                results.Add(sym);

            descOffset += 20;
        }

        return results;
    }

    // IMAGE_DELAYLOAD_DESCRIPTOR is 32 bytes
    private static IEnumerable<ImportSymbol> ReadDelayImportDescriptors(byte[] bytes, PEHeaders headers, int delayDirRva, bool is64)
    {
        var results = new List<ImportSymbol>();
        int descOffset = RvaToOffset(headers, delayDirRva);

        while (true)
        {
            uint attributes = ReadU32(bytes, descOffset + 0);
            uint nameRva    = ReadU32(bytes, descOffset + 4);
            uint hmod       = ReadU32(bytes, descOffset + 8);
            uint iatRva     = ReadU32(bytes, descOffset + 12);
            uint intRva     = ReadU32(bytes, descOffset + 16);
            uint boundRva   = ReadU32(bytes, descOffset + 20);
            uint unloadRva  = ReadU32(bytes, descOffset + 24);
            uint ts         = ReadU32(bytes, descOffset + 28);

            if (attributes == 0 && nameRva == 0 && hmod == 0 && iatRva == 0 && intRva == 0 && boundRva == 0 && unloadRva == 0 && ts == 0)
                break;

            string dllName = ReadAsciiZ(bytes, RvaToOffset(headers, (int)nameRva));

            // INT (Import Name Table) is at intRva; format is similar to normal thunk array.
            int thunkOffset = RvaToOffset(headers, (int)intRva);
            foreach (var sym in ReadThunkArray(bytes, headers, thunkOffset, is64, dllName))
                results.Add(sym);

            descOffset += 32;
        }

        return results;
    }

    private static IEnumerable<ImportSymbol> ReadThunkArray(byte[] bytes, PEHeaders headers, int thunkOffset, bool is64, string dllName)
    {
        var results = new List<ImportSymbol>();
        int cursor = thunkOffset;

        while (true)
        {
            ulong thunk = is64 ? ReadU64(bytes, cursor) : ReadU32(bytes, cursor);
            if (thunk == 0) break;

            bool isOrdinal = is64
                ? (thunk & 0x8000_0000_0000_0000UL) != 0
                : (thunk & 0x8000_0000UL) != 0;

            if (isOrdinal)
            {
                ushort ordinal = (ushort)(thunk & 0xFFFF);
                results.Add(new ImportSymbol(dllName, "#" + ordinal));
            }
            else
            {
                int nameRva = (int)(thunk & (is64 ? 0x7FFF_FFFF_FFFF_FFFFUL : 0x7FFF_FFFFUL));
                int nameOff = RvaToOffset(headers, nameRva);

                // IMAGE_IMPORT_BY_NAME: WORD Hint; CHAR Name[]
                int strOff = nameOff + 2;
                string func = ReadAsciiZ(bytes, strOff);

                results.Add(new ImportSymbol(dllName, func));
            }

            cursor += is64 ? 8 : 4;
        }

        return results;
    }

    private static int RvaToOffset(PEHeaders headers, int rva)
    {
        // If it lives in the PE headers, RVA == file offset.
        if (rva < headers.PEHeader!.SizeOfHeaders)
            return rva;

        foreach (var s in headers.SectionHeaders)
        {
            int start = s.VirtualAddress;
            int end = start + Math.Max(s.VirtualSize, s.SizeOfRawData);
            if (rva >= start && rva < end)
                return (rva - start) + s.PointerToRawData;
        }

        // Fallback (best-effort).
        return rva;
    }

    private static uint ReadU32(byte[] b, int off) =>
        BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, off, 4));

    private static ulong ReadU64(byte[] b, int off) =>
        BinaryPrimitives.ReadUInt64LittleEndian(new ReadOnlySpan<byte>(b, off, 8));

    private static string ReadAsciiZ(byte[] bytes, int offset)
    {
        int i = offset;
        while (i < bytes.Length && bytes[i] != 0) i++;
        if (i <= offset) return "";
        return Encoding.ASCII.GetString(bytes, offset, i - offset);
    }

    // ---------- Win32 metadata mapping ----------

    private sealed record WinApiInfo(int MinBuild, string Reason);

    private static Dictionary<string, WinApiInfo> BuildApiMinBuildMap(string winmdPath)
    {
        var map = new Dictionary<string, WinApiInfo>(StringComparer.OrdinalIgnoreCase);

        using var fs = File.OpenRead(winmdPath);
        using var peReader = new PEReader(fs);

        var md = peReader.GetMetadataReader();

        foreach (var tHandle in md.TypeDefinitions)
        {
            var t = md.GetTypeDefinition(tHandle);

            foreach (var mHandle in t.GetMethods())
            {
                var m = md.GetMethodDefinition(mHandle);

                // Read DllImport + EntryPoint
                if (!TryReadDllImport(md, mHandle, out var dll, out var entryPoint))
                    continue;

                if (string.IsNullOrWhiteSpace(dll))
                    continue;

                if (string.IsNullOrWhiteSpace(entryPoint))
                    entryPoint = md.GetString(m.Name);

                dll = NormalizeModuleName(dll);
                entryPoint = entryPoint.Trim();

                // Determine supported build from attributes
                var (minBuild, reason) = ExtractMinBuildFromAttributes(md, mHandle);
                var info = new WinApiInfo(minBuild, reason);

                // Add a few variants so imports can match regardless of ".dll" suffix.
                foreach (var moduleVariant in ModuleNameVariants(dll))
                {
                    foreach (var key in KeyVariants(moduleVariant, entryPoint))
                    {
                        // Keep the "most restrictive" (highest min build) if duplicates appear.
                        if (map.TryGetValue(key, out var existing))
                        {
                            if (info.MinBuild > existing.MinBuild)
                                map[key] = info;
                        }
                        else
                        {
                            map[key] = info;
                        }
                    }
                }
            }
        }

        return map;
    }

    private static IEnumerable<string> ModuleNameVariants(string dll)
    {
        var d = NormalizeModuleName(dll);
        yield return d;

        if (d.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
        {
            yield return d[..^4];
        }
        else
        {
            yield return d + ".dll";
        }
    }

    private static IEnumerable<string> KeyVariants(string dll, string func)
    {
        // Primary key
        yield return $"{dll}!{func}";

        // Win32 APIs often have A/W suffix; allow matching without it.
        if (func.EndsWith("A", StringComparison.Ordinal) || func.EndsWith("W", StringComparison.Ordinal))
        {
            var baseName = func[..^1];
            yield return $"{dll}!{baseName}";
        }
    }

    private static (int MinBuild, string Reason) LookupApi(Dictionary<string, WinApiInfo> map, string dll, string func)
    {
        dll = NormalizeModuleName(dll);
        func = func.Trim();

        foreach (var moduleVariant in ModuleNameVariants(dll))
        {
            foreach (var key in KeyVariants(moduleVariant, func))
            {
                if (map.TryGetValue(key, out var info))
                    return (info.MinBuild, info.Reason);
            }
        }

        // Not found.
        return (0, "");
    }

    private static string NormalizeModuleName(string dll)
    {
        dll = (dll ?? "").Trim().Trim('"');
        return dll.ToLowerInvariant();
    }

    private static bool TryReadDllImport(MetadataReader md, MethodDefinitionHandle mHandle, out string dllName, out string entryPoint)
    {
        dllName = "";
        entryPoint = "";

        // DllImport info is stored as an ImplMap + PInvoke attributes.
        var method = md.GetMethodDefinition(mHandle);
        if ((method.Attributes & System.Reflection.MethodAttributes.PinvokeImpl) == 0)
            return false;

        // Resolve ImplMap to read module name + import name.
        if (method.GetImport() is not { } import)
            return false;

        var moduleRef = md.GetModuleReference(import.Module);
        dllName = md.GetString(moduleRef.Name);

        // Import name: can be set or default.
        if (!import.Name.IsNil)
            entryPoint = md.GetString(import.Name);

        return true;
    }

    private static (int MinBuild, string Reason) ExtractMinBuildFromAttributes(MetadataReader md, MethodDefinitionHandle methodHandle)
    {
        int bestBuild = 0;
        string bestReason = "";

        var method = md.GetMethodDefinition(methodHandle);

        foreach (var caHandle in method.GetCustomAttributes())
        {
            var ca = md.GetCustomAttribute(caHandle);
            var typeName = GetAttributeTypeFullName(md, ca.Constructor);
            if (typeName is null) continue;

            // Support both:
            //   System.Runtime.Versioning.SupportedOSPlatformAttribute
            //   System.Runtime.Versioning.SupportedOSPlatformGuardAttribute (ignore)
            if (!typeName.EndsWith("SupportedOSPlatformAttribute", StringComparison.Ordinal))
                continue;

            string? arg = TryGetFirstStringCtorArg(md, ca);
            if (string.IsNullOrWhiteSpace(arg)) continue;

            // typical values: "windows10.0.19041" or "windows10.0.10240.0"
            int build = ExtractBuildNumber(arg!);
            if (build > bestBuild)
            {
                bestBuild = build;
                bestReason = arg!;
            }
        }

        return (bestBuild, bestReason);
    }

    private static int ExtractBuildNumber(string platformString)
    {
        // We mainly care about Windows 10/11 build numbers, because Win32Metadata is precise there.
        // Example: windows10.0.19041.0 -> 19041
        // If no build is present (e.g., windows6.1), return 0 (unknown/older).
        if (string.IsNullOrWhiteSpace(platformString)) return 0;

        // Find last numeric segment >= 10000 (Windows 10+ builds are 5 digits).
        int best = 0;
        var segs = platformString.Split('.', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (var s in segs)
        {
            if (int.TryParse(s, out int n) && n >= 10000)
                best = Math.Max(best, n);
        }
        return best;
    }

    private static string? TryGetFirstStringCtorArg(MetadataReader md, CustomAttribute ca)
    {
        // CustomAttribute value is a blob:
        //  Prolog (0x0001) + fixed args + named args
        // For SupportedOSPlatformAttribute, fixed args = 1 string.
        var blob = md.GetBlobBytes(ca.Value);
        if (blob.Length < 4) return null;

        int offset = 0;
        ushort prolog = BinaryPrimitives.ReadUInt16LittleEndian(blob.AsSpan(offset, 2));
        offset += 2;
        if (prolog != 0x0001) return null;

        // Read serialized string:
        //  - if first byte == 0xFF => null
        //  - else compressed length + UTF8 bytes
        if (offset >= blob.Length) return null;
        byte first = blob[offset];
        if (first == 0xFF) return null;

        if (!TryReadCompressedUInt(blob, ref offset, out int len)) return null;
        if (len < 0 || offset + len > blob.Length) return null;

        var str = Encoding.UTF8.GetString(blob, offset, len);
        return str;
    }

    private static bool TryReadCompressedUInt(byte[] blob, ref int offset, out int value)
    {
        value = 0;
        if (offset >= blob.Length) return false;

        byte b1 = blob[offset++];

        // ECMA-335 compressed integer
        if ((b1 & 0x80) == 0)
        {
            value = b1;
            return true;
        }
        if ((b1 & 0xC0) == 0x80)
        {
            if (offset >= blob.Length) return false;
            byte b2 = blob[offset++];
            value = ((b1 & 0x3F) << 8) | b2;
            return true;
        }
        if ((b1 & 0xE0) == 0xC0)
        {
            if (offset + 2 >= blob.Length) return false;
            byte b2 = blob[offset++];
            byte b3 = blob[offset++];
            byte b4 = blob[offset++];
            value = ((b1 & 0x1F) << 24) | (b2 << 16) | (b3 << 8) | b4;
            return true;
        }

        return false;
    }

    private static string? GetAttributeTypeFullName(MetadataReader md, EntityHandle ctor)
    {
        // ctor can be MethodDefinition or MemberReference
        if (ctor.Kind == HandleKind.MemberReference)
        {
            var mr = md.GetMemberReference((MemberReferenceHandle)ctor);
            return GetTypeFullName(md, mr.Parent);
        }
        if (ctor.Kind == HandleKind.MethodDefinition)
        {
            var mdh = md.GetMethodDefinition((MethodDefinitionHandle)ctor);
            return GetTypeFullName(md, mdh.GetDeclaringType());
        }
        return null;
    }

    private static string? GetTypeFullName(MetadataReader md, EntityHandle typeHandle)
    {
        if (typeHandle.Kind == HandleKind.TypeReference)
        {
            var tr = md.GetTypeReference((TypeReferenceHandle)typeHandle);
            var ns = tr.Namespace.IsNil ? "" : md.GetString(tr.Namespace);
            var name = md.GetString(tr.Name);
            return string.IsNullOrEmpty(ns) ? name : ns + "." + name;
        }
        if (typeHandle.Kind == HandleKind.TypeDefinition)
        {
            var td = md.GetTypeDefinition((TypeDefinitionHandle)typeHandle);
            var ns = td.Namespace.IsNil ? "" : md.GetString(td.Namespace);
            var name = md.GetString(td.Name);
            return string.IsNullOrEmpty(ns) ? name : ns + "." + name;
        }
        return null;
    }

    private static string CsvEscape(string s)
    {
        s ??= "";
        if (s.Contains(',') || s.Contains('"') || s.Contains('\n') || s.Contains('\r'))
        {
            return "\"" + s.Replace("\"", "\"\"") + "\"";
        }
        return s;
    }
}
