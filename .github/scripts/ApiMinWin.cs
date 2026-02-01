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
/// ApiMinWin (dumpbin-based, deterministic)
/// --------------------------------------
/// Inputs:
///   1) Windows.Win32.winmd (Win32Metadata)  -> API -> SupportedOSPlatform(min version)
///   2) dumpbin /imports output (imports.txt) -> imported (dll, func) pairs
///   3) dumpbin /headers output (headers.txt) -> subsystem/OS version fields
///
/// Output:
///   requiredMinBuild = max(apiMinBuild, headerMinBuild)
///   with reasons so you can trace why.
///
/// Why this avoids "all zeros":
///   - It no longer assumes SupportedOSPlatform always contains build numbers.
///     e.g. "windows7.0", "windows8.1", "windows10.0" are mapped to baseline builds.
///   - It uses dumpbin output (same as the VS Dev Prompt workflow) rather than custom PE parsing.
///   - It can map common API-set import DLLs (api-ms-win-*/ext-ms-win-*) to their likely host DLL families
///     (kernel32/kernelbase/user32/gdi32/advapi32/rpcrt4/ws2_32/ole32/combase/shell32).
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
            var importsPath = GetArgValue(args, "--imports") ?? GetArgValue(args, "-i");
            var headersPath = GetArgValue(args, "--headers") ?? GetArgValue(args, "-H");
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

            if (!string.IsNullOrWhiteSpace(importsPath))
            {
                if (!File.Exists(importsPath))
                {
                    Console.Error.WriteLine($"ERROR: imports file not found: {importsPath}");
                    return 3;
                }

                int headerMinBuild = 0;
                string headerMinReason = "N/A";
                if (!string.IsNullOrWhiteSpace(headersPath))
                {
                    if (!File.Exists(headersPath))
                    {
                        Console.Error.WriteLine($"ERROR: headers file not found: {headersPath}");
                        return 4;
                    }
                    (headerMinBuild, headerMinReason) = ParseDumpbinHeaders(headersPath);
                }

                var imports = ParseDumpbinImports(importsPath);
                int importCount = imports.Count;

                int mappedImportCount = 0;
                int apiMinBuild = 0;
                string apiMinReason = "N/A";

                foreach (var (dll, func) in imports)
                {
                    if (func.StartsWith("#", StringComparison.Ordinal))
                        continue;

                    var (b, reason) = LookupApi(map, dll, func);
                    if (b > 0 || !string.IsNullOrWhiteSpace(reason))
                        mappedImportCount++;

                    if (b > apiMinBuild)
                    {
                        apiMinBuild = b;
                        apiMinReason = $"{dll}!{func} -> {reason}";
                    }
                }

                
                // Some components have documented minimum supported OS versions based on DLL presence.
                // Example: dxcore.dll requires Windows 10, version 2004 (build 19041).
                //          directml.dll inbox since Windows 10, version 1903 (build 18362).
                var importedModules = imports.Select(p => NormalizeModuleName(p.Dll)).Distinct(StringComparer.OrdinalIgnoreCase);
                (int dllMinBuild, string dllMinReason) = GetMinBuildFromKnownDlls(importedModules);
int required = Math.Max(apiMinBuild, headerMinBuild);
                string reqReason = required == 0 ? "UNKNOWN" :
                                   required == apiMinBuild ? $"API: {apiMinReason}" :
                                   $"HEADERS: {headerMinReason}";

                var result = new AnalyzeResult(
                    ImportsPath: importsPath,
                    HeaderPath: headersPath ?? "",
                    ImportCount: importCount,
                    MappedImportCount: mappedImportCount,
                    ApiMinBuild: apiMinBuild,
                    ApiMinReason: apiMinReason,
                    HeaderMinBuild: headerMinBuild,
                    HeaderMinReason: headerMinReason,
                    DllMinBuild: dllMinBuild,
                    DllMinReason: dllMinReason,
                    RequiredMinBuild: required,
                    RequiredMinReason: reqReason
                );

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
                    Console.WriteLine($"imports={result.ImportsPath}");
                    Console.WriteLine($"headers={result.HeaderPath}");
                    Console.WriteLine($"importCount={result.ImportCount}");
                    Console.WriteLine($"mappedImportCount={result.MappedImportCount}");
                    Console.WriteLine($"apiMinBuild={result.ApiMinBuild}");
                    Console.WriteLine($"apiMinReason={result.ApiMinReason}");
                    Console.WriteLine($"headerMinBuild={result.HeaderMinBuild}");
                    Console.WriteLine($"headerMinReason={result.HeaderMinReason}");
                    Console.WriteLine($"dllMinBuild={result.DllMinBuild}");
                    Console.WriteLine($"dllMinReason={result.DllMinReason}");
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
@"ApiMinWin - infer minimum Windows build (deterministic, dumpbin-based)

USAGE:
  # Main mode: analyze dumpbin outputs
  ApiMinWin --winmd <Windows.Win32.winmd> --imports <dumpbin_imports.txt> --headers <dumpbin_headers.txt> [--json]

  # Legacy stdin mapping (dll,func per line)
  ApiMinWin --winmd <Windows.Win32.winmd>
    stdin:  kernel32.dll,CreateFileW
    stdout: dll,func,minBuild,reason

NOTES:
  - --winmd can also be a .txt file whose first non-empty line is the winmd path (back-compat).
  - Build mapping baselines:
      Vista 6.0 -> 6000
      Win7  6.1 / 7.0 -> 7600
      Win8  6.2 / 8.0 -> 9200
      Win8.1 6.3 / 8.1 -> 9600
      Win10 10.0 -> 10240 (unless a specific build is present, e.g. 19041)
");
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

    // ---------- Result ----------
    private sealed record AnalyzeResult(
        string ImportsPath,
        string HeaderPath,
        int ImportCount,
        int MappedImportCount,
        int ApiMinBuild,
        string ApiMinReason,
        int HeaderMinBuild,
        string HeaderMinReason,
        int DllMinBuild,
        string DllMinReason,
        int RequiredMinBuild,
        string RequiredMinReason
    );

    private readonly record struct ImportSymbol(string Module, string Symbol);

    // ---------- dumpbin parsing ----------
    private static List<(string Dll, string Func)> ParseDumpbinImports(string importsTxtPath)
    {
        var lines = File.ReadAllLines(importsTxtPath);
        var pairs = new List<(string Dll, string Func)>();

        string? currentDll = null;

        foreach (var raw in lines)
        {
            var line = raw.TrimEnd();
            var t = line.Trim();
            if (t.Length == 0) continue;

            // A DLL header line typically looks like:
            //   KERNEL32.dll
            //   api-ms-win-core-synch-l1-2-0.dll
            if (LooksLikeDllNameLine(t))
            {
                currentDll = t;
                continue;
            }

            if (currentDll == null) continue;

            // Skip structural lines
            if (t.Contains("Import Address Table", StringComparison.OrdinalIgnoreCase) ||
                t.Contains("Import Name Table", StringComparison.OrdinalIgnoreCase) ||
                t.Contains("time date stamp", StringComparison.OrdinalIgnoreCase) ||
                t.Contains("Index of first forwarder reference", StringComparison.OrdinalIgnoreCase) ||
                t.StartsWith("Summary", StringComparison.OrdinalIgnoreCase) ||
                t.StartsWith("Section contains", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            // Typical import lines:
            //   0000000180001040 GetTickCount64
            //   0000000180001048 ExitProcess
            // Sometimes dumpbin prints ordinal-only imports; keep as "#123"
            var sym = TryParseImportSymbol(t);
            if (sym == null) continue;

            pairs.Add((currentDll, sym));
        }

        return pairs;
    }

    private static bool LooksLikeDllNameLine(string t)
    {
        // tolerate "KERNEL32.dll" or "KERNEL32.DLL"
        if (t.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)) return true;

        // Some dumpbin prints "KERNEL32.dll:" with a colon
        if (t.EndsWith(".dll:", StringComparison.OrdinalIgnoreCase)) return true;

        return false;
    }

    private static string? TryParseImportSymbol(string t)
    {
        // Ordinal line patterns (rare):
        //   ordinal 123
        //   #123
        if (t.StartsWith("#", StringComparison.Ordinal))
            return t;

        if (t.StartsWith("ordinal", StringComparison.OrdinalIgnoreCase))
        {
            var parts = t.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 2 && int.TryParse(parts[1], out var ord))
                return "#" + ord;
        }

        // Common: <hex> <symbol>
        // We'll accept 1 hex column and take the last token as symbol.
        // Example: "0000000180001040 GetTickCount64"
        var parts2 = t.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts2.Length >= 2 && IsHex(parts2[0]))
        {
            var last = parts2[^1];
            // Some lines end with "forwarded to ..." - ignore
            if (last.Equals("to", StringComparison.OrdinalIgnoreCase)) return null;
            // Trim decorations like "GetProcAddress,"? usually not.
            return last;
        }

        return null;
    }

    private static bool IsHex(string s)
    {
        if (s.Length < 4) return false;
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            bool ok = (c >= '0' && c <= '9') ||
                      (c >= 'a' && c <= 'f') ||
                      (c >= 'A' && c <= 'F');
            if (!ok) return false;
        }
        return true;
    }

    private static (int MinBuild, string Reason) ParseDumpbinHeaders(string headersTxtPath)
    {
        // We take the max of:
        //   operating system version
        //   subsystem version
        // Dumpbin headers include lines like:
        //   6.01 operating system version
        //   6.01 subsystem version
        int best = 0;
        string bestReason = "N/A";

        foreach (var raw in File.ReadAllLines(headersTxtPath))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;

            if (line.EndsWith("operating system version", StringComparison.OrdinalIgnoreCase) ||
                line.EndsWith("subsystem version", StringComparison.OrdinalIgnoreCase))
            {
                // Format: "<major>.<minor> <text...>"
                var first = line.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
                if (first == null) continue;

                if (TryParseMajorMinor(first, out var major, out var minor))
                {
                    var b = OsMajorMinorToBaselineBuild(major, minor);
                    if (b > best)
                    {
                        best = b;
                        bestReason = $"{line} -> baseline build {b}";
                    }
                }
            }
        }

        return (best, bestReason);
    }

    private static bool TryParseMajorMinor(string s, out int major, out int minor)
    {
        major = 0; minor = 0;
        var p = s.Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (p.Length != 2) return false;
        return int.TryParse(p[0], out major) && int.TryParse(p[1], out minor);
    }

    // ---------- Win32 metadata mapping ----------
    private sealed record WinApiInfo(int MinBuild, string PlatformString);

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

                if ((m.Attributes & System.Reflection.MethodAttributes.PinvokeImpl) == 0)
                    continue;

                // Resolve ImplMap to read module name + import name.
                var import = m.GetImport();
                if (import.Module.IsNil)
                    continue;

                var moduleRef = md.GetModuleReference(import.Module);
                var dll = md.GetString(moduleRef.Name);
                if (string.IsNullOrWhiteSpace(dll))
                    continue;

                string entryPoint;
                if (!import.Name.IsNil)
                    entryPoint = md.GetString(import.Name);
                else
                    entryPoint = md.GetString(m.Name);

                if (string.IsNullOrWhiteSpace(entryPoint))
                    continue;

                dll = NormalizeModuleName(dll);
                entryPoint = entryPoint.Trim();

                var (minBuild, platformString) = ExtractMinBuildFromAttributes(md, mHandle);
                var info = new WinApiInfo(minBuild, platformString);

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

        // 1) Direct match
        foreach (var moduleVariant in ModuleNameVariants(dll))
        {
            foreach (var key in KeyVariants(moduleVariant, func))
            {
                if (map.TryGetValue(key, out var info))
                    return (info.MinBuild, info.PlatformString);
            }
        }

        // 2) API-set fallback (deterministic-ish mapping to host families)
        foreach (var fallback in ApiSetFallbackModules(dll))
        {
            foreach (var moduleVariant in ModuleNameVariants(fallback))
            {
                foreach (var key in KeyVariants(moduleVariant, func))
                {
                    if (map.TryGetValue(key, out var info))
                        return (info.MinBuild, info.PlatformString);
                }
            }
        }

        return (0, "");
    }

    private static IEnumerable<string> ApiSetFallbackModules(string dll)
    {
        // This is not a perfect mapping of ApiSetSchema, but it substantially reduces false "0"
        // when binaries import api-ms-win-* / ext-ms-win-* instead of classic DLLs.
        var d = NormalizeModuleName(dll);

        if (!(d.StartsWith("api-ms-win-", StringComparison.OrdinalIgnoreCase) ||
              d.StartsWith("ext-ms-win-", StringComparison.OrdinalIgnoreCase)))
            yield break;

        // CRT api-sets -> not Win32Metadata P/Invoke (skip)
        if (d.StartsWith("api-ms-win-crt-", StringComparison.OrdinalIgnoreCase))
            yield break;

        if (d.Contains("-user-", StringComparison.OrdinalIgnoreCase) || d.Contains("-user32-", StringComparison.OrdinalIgnoreCase))
        {
            yield return "user32.dll";
            yield break;
        }

        if (d.Contains("-gdi-", StringComparison.OrdinalIgnoreCase) || d.Contains("-gdi32-", StringComparison.OrdinalIgnoreCase))
        {
            yield return "gdi32.dll";
            yield break;
        }

        if (d.Contains("-shell-", StringComparison.OrdinalIgnoreCase))
        {
            yield return "shell32.dll";
            yield break;
        }

        if (d.Contains("-ole-", StringComparison.OrdinalIgnoreCase))
        {
            yield return "ole32.dll";
            yield return "combase.dll";
            yield break;
        }

        if (d.Contains("-com-", StringComparison.OrdinalIgnoreCase))
        {
            yield return "combase.dll";
            yield return "ole32.dll";
            yield break;
        }

        if (d.Contains("-rpc-", StringComparison.OrdinalIgnoreCase))
        {
            yield return "rpcrt4.dll";
            yield break;
        }

        if (d.Contains("-security-", StringComparison.OrdinalIgnoreCase) || d.Contains("-advapi-", StringComparison.OrdinalIgnoreCase))
        {
            yield return "advapi32.dll";
            yield break;
        }

        if (d.Contains("-winsock-", StringComparison.OrdinalIgnoreCase) || d.Contains("-ws2-", StringComparison.OrdinalIgnoreCase))
        {
            yield return "ws2_32.dll";
            yield break;
        }

        // Default for "core" families: try kernelbase/kernel32.
        yield return "kernelbase.dll";
        yield return "kernel32.dll";
    }

    
    private static readonly Dictionary<string, (int Build, string Reason)> KnownDllMinBuild
        = new(StringComparer.OrdinalIgnoreCase)
        {
            // Official requirements:
            //   - DXCore: Windows 10, version 2004 (10.0; Build 19041)
            //   - DirectML inbox: Windows 10, version 1903 (10.0; Build 18362)
            ["dxcore.dll"] = (19041, "imports dxcore.dll (min Windows 10 2004 / 19041)"),
            ["directml.dll"] = (18362, "imports directml.dll (min Windows 10 1903 / 18362)"),
        };

    private static (int MinBuild, string Reason) GetMinBuildFromKnownDlls(IEnumerable<string> importedModules)
    {
        int best = 0;
        string bestReason = "N/A";

        foreach (var m in importedModules)
        {
            var mod = NormalizeModuleName(m);
            if (KnownDllMinBuild.TryGetValue(mod, out var info))
            {
                if (info.Build > best)
                {
                    best = info.Build;
                    bestReason = info.Reason;
                }
            }
        }

        return (best, bestReason);
    }

private static string NormalizeModuleName(string dll)
    {
        dll = (dll ?? "").Trim().Trim('"');
        if (dll.EndsWith(":", StringComparison.Ordinal))
            dll = dll[..^1];
        return dll.ToLowerInvariant();
    }

    private static (int MinBuild, string PlatformString) ExtractMinBuildFromAttributes(MetadataReader md, MethodDefinitionHandle methodHandle)
    {
        int bestBuild = 0;
        string bestPlatform = "";

        var method = md.GetMethodDefinition(methodHandle);

        foreach (var caHandle in method.GetCustomAttributes())
        {
            var ca = md.GetCustomAttribute(caHandle);
            var typeName = GetAttributeTypeFullName(md, ca.Constructor);
            if (typeName is null) continue;

            if (!typeName.EndsWith("SupportedOSPlatformAttribute", StringComparison.Ordinal))
                continue;

            string? arg = TryGetFirstStringCtorArg(md, ca);
            if (string.IsNullOrWhiteSpace(arg)) continue;

            int build = PlatformStringToMinBuild(arg!);
            if (build > bestBuild)
            {
                bestBuild = build;
                bestPlatform = arg!;
            }
            else if (build == bestBuild && bestPlatform.Length == 0)
            {
                bestPlatform = arg!;
            }
        }

        return (bestBuild, bestPlatform.Length == 0 ? "N/A" : bestPlatform);
    }

    private static int PlatformStringToMinBuild(string platformString)
    {
        // Examples:
        //   windows6.0
        //   windows7.0
        //   windows8.1
        //   windows10.0
        //   windows10.0.19041
        //   windows10.0.19041.0
        if (string.IsNullOrWhiteSpace(platformString)) return 0;

        var s = platformString.Trim().ToLowerInvariant();
        if (s.StartsWith("windows", StringComparison.OrdinalIgnoreCase))
            s = s.Substring("windows".Length);

        // Strip leading separators
        s = s.TrimStart('.', ' ');

        // Extract numeric segments
        var segs = s.Split('.', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var nums = new List<int>();
        foreach (var seg in segs)
        {
            if (int.TryParse(seg, out var n))
                nums.Add(n);
            else
                break;
        }

        // If contains a Win10+ build (>= 10000), use it.
        foreach (var n in nums)
        {
            if (n >= 10000)
                return n;
        }

        // Interpret marketing versions (7.0/8.0/8.1) or OS major/minor (6.x/10.0).
        // nums could be [7,0] or [6,1] or [10,0]
        if (nums.Count >= 1)
        {
            int major = nums[0];
            int minor = nums.Count >= 2 ? nums[1] : 0;

            // Marketing shortcut: 7.0/8.0/8.1 (not real NT major)
            if (major == 7) return 7600;
            if (major == 8 && minor == 0) return 9200;
            if (major == 8 && minor == 1) return 9600;

            return OsMajorMinorToBaselineBuild(major, minor);
        }

        return 0;
    }

    private static int OsMajorMinorToBaselineBuild(int major, int minor)
    {
        // Baseline build mapping (stable, deterministic)
        // NT 6.0 Vista -> 6000
        // NT 6.1 Win7  -> 7600
        // NT 6.2 Win8  -> 9200
        // NT 6.3 Win8.1-> 9600
        // NT 10.0 Win10 baseline -> 10240
        if (major == 6 && minor == 0) return 6000;
        if (major == 6 && minor == 1) return 7600;
        if (major == 6 && minor == 2) return 9200;
        if (major == 6 && minor == 3) return 9600;
        if (major == 10 && minor == 0) return 10240;

        return 0;
    }

    private static string? TryGetFirstStringCtorArg(MetadataReader md, CustomAttribute ca)
    {
        // CustomAttribute value blob:
        //  Prolog (0x0001) + fixed args + named args
        // For SupportedOSPlatformAttribute, fixed args = 1 string.
        var blob = md.GetBlobBytes(ca.Value);
        if (blob.Length < 4) return null;

        int offset = 0;
        ushort prolog = BinaryPrimitives.ReadUInt16LittleEndian(blob.AsSpan(offset, 2));
        offset += 2;
        if (prolog != 0x0001) return null;

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
