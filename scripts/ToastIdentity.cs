using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace TiboWatch {
    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey {
        public Guid Format;
        public uint Id;
    }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    internal struct PropVariant {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Text;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }
    public static class ShortcutIdentity {
        public static void SetAppId(string path, string appId) {
            object shellLink = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
            IntPtr text = IntPtr.Zero;
            try {
                var file = (IPersistFile)shellLink;
                file.Load(path, 2);
                var store = (IPropertyStore)shellLink;
                var key = new PropertyKey { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 5 };
                text = Marshal.StringToCoTaskMemUni(appId);
                var value = new PropVariant { Type = 31, Text = text };
                store.SetValue(ref key, ref value);
                store.Commit();
                file.Save(path, true);
            } finally {
                if (text != IntPtr.Zero) Marshal.FreeCoTaskMem(text);
                Marshal.FinalReleaseComObject(shellLink);
            }
        }
    }
}
