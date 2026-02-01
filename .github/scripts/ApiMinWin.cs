using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;

class Program
{
    static void Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: ApiMinWin <path-to-Windows.Win32.winmd>");
            Environment.Exit(2);
        }

        var winmdPath = args[0];
        if (!File.Exists(winmdPath))
        {
            Console.Error.WriteLine($"winmd not found: {winmdPath}");
            Environment.Exit(2);
        }

        var map = BuildMap(winmdPath);
        Console.Error.WriteLine($"[ApiMinWin] map size = {map.Count}");

        // Output header
        Console.WriteLine("dll,func,minBuild,reason");

        string line;
        while ((line = Console.ReadLine()) != null)
        {
            line = line.Trim();
            if (line.Length == 0) continue;

            var parts = line.Split(',', 2);
            if (parts.Length < 2) continue;

            var dll = parts[0].Trim().ToLowerInvariant();
            var func = parts[1].Trim();

            var key = dll + "!" + func;
            if (map.TryGetValue(key, out var v))
            {
                Console.WriteLine($"{dll},{Escape(func)},{v.minBuild},{Escape(v.reason)}");
            }
            else
            {
                var alt = TryAltKeys(dll, func);
                if (alt != null && map.TryGetValue(alt, out v))
                {
                    Console.WriteLine($"{dll},{Escape(func)},{v.minBuild},{Escape(v.reason)}");
                }
                else
                {
                    Console.WriteLine($"{dll},{Escape(func)},,");
                }
            }
        }
    }

    static string Escape(string s)
    {
        if (s.Contains(',') || s.Contains('"'))
            return "\"" + s.Replace("\"", "\"\"") + "\"";
        return s;
    }

    static string? TryAltKeys(string dll, string func)
    {
        if (func.Length > 1)
        {
            char last = func[^1];
            if (last == 'A' || last == 'W')
            {
                return dll + "!" + func.Substring(0, func.Length - 1);
            }
        }
        return null;
    }

    static Dictionary<string, (int minBuild, string reason)> BuildMap(string winmdPath)
    {
        using var fs = File.OpenRead(winmdPath);
        using var pe = new PEReader(fs);
        var md = pe.GetMetadataReader();

        var dllImportType = "System.Runtime.InteropServices.DllImportAttribute";
        var supportedType = "System.Runtime.Versioning.SupportedOSPlatformAttribute";

        var map = new Dictionary<string, (int, string)>(StringComparer.OrdinalIgnoreCase);

        foreach (var typeHandle in md.TypeDefinitions)
        {
            var type = md.GetTypeDefinition(typeHandle);

            foreach (var methodHandle in type.GetMethods())
            {
                var method = md.GetMethodDefinition(methodHandle);

                string? dllName = null;
                string? entryPoint = null;
                int minBuild = 0;
                string? minReason = null;

                foreach (var caHandle in method.GetCustomAttributes())
                {
                    var ca = md.GetCustomAttribute(caHandle);
                    var attrName = GetAttributeTypeFullName(md, ca);
                    if (attrName == null) continue;

                    if (attrName == dllImportType)
                    {
                        ReadDllImport(md, ca, out dllName, out entryPoint);
                    }
                    else if (attrName == supportedType)
                    {
                        var plat = ReadSingleStringCtorArg(md, ca);
                        if (plat != null)
                        {
                            var build = ExtractBuild(plat);
                            if (build > minBuild)
                            {
                                minBuild = build;
                                minReason = plat;
                            }
                        }
                    }
                }

                if (dllName == null) continue;

                var dllLower = dllName.Trim().ToLowerInvariant();
                var ep = entryPoint ?? md.GetString(method.Name);
                if (string.IsNullOrWhiteSpace(ep)) continue;

                var key = dllLower + "!" + ep;
                if (!map.TryGetValue(key, out var existing) || minBuild > existing.minBuild)
                {
                    var reason = minReason ?? "";
                    map[key] = (minBuild, reason);
                }
            }
        }

        return map;
    }

    static int ExtractBuild(string s)
    {
        var parts = s.Split('.', StringSplitOptions.RemoveEmptyEntries);
        foreach (var p in parts)
        {
            if (int.TryParse(p, out int v) && v >= 10000) return v;
        }
        return 0;
    }

    static string? ReadSingleStringCtorArg(MetadataReader md, CustomAttribute ca)
    {
        var value = ca.Value;
        var blob = md.GetBlobReader(value);
        if (blob.ReadUInt16() != 1) return null;
        return blob.ReadSerializedString();
    }

    static void ReadDllImport(MetadataReader md, CustomAttribute ca, out string? dllName, out string? entryPoint)
    {
        dllName = null;
        entryPoint = null;

        var blob = md.GetBlobReader(ca.Value);
        if (blob.ReadUInt16() != 1) return;

        dllName = blob.ReadSerializedString();

        if (blob.Offset >= blob.Length) return;

        ushort numNamed = blob.ReadUInt16();
        for (int i = 0; i < numNamed; i++)
        {
            byte kind = blob.ReadByte(); 
            byte type = blob.ReadByte(); 
            string? name = blob.ReadSerializedString();
            object? val = ReadFixedArg(md, ref blob, type);
            if (name != null && name.Equals("EntryPoint", StringComparison.OrdinalIgnoreCase))
            {
                entryPoint = val as string;
            }
        }
    }

    static object? ReadFixedArg(MetadataReader md, ref BlobReader blob, byte et)
    {
        if (et == 0x0E)
        {
            return blob.ReadSerializedString();
        }
        SkipFixedArg(ref blob, et);
        return null;
    }

    static void SkipFixedArg(ref BlobReader blob, byte et)
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
            default: break;
        }
    }

    static string? GetAttributeTypeFullName(MetadataReader md, CustomAttribute ca)
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
        if (string.IsNullOrEmpty(ns)) return name;
        return ns + "." + name;
    }
}
