#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $SaveDirectory
)

$ErrorActionPreference = 'Stop'

if (-not ('P5RRoyalResume.V2.SaveCodec' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace P5RRoyalResume.V2
{
    public enum SaveAction
    {
        Unavailable,
        SkipFinalBattle,
        AfterBattle,
        PrepareNovember18,
        UnlockRoyalRoute,
        AlreadyReady,
        ThirdSemester,
        ClearData,
        PastBranch
    }

    public sealed class SlotInfo
    {
        public string Hash { get; internal set; }
        public string FormatError { get; internal set; }
        public string Title { get; internal set; }
        public int Day { get; internal set; }
        public int Time { get; internal set; }
        public int Level { get; internal set; }
        public int PlayMinutes { get; internal set; }
        public int CouncillorRank { get; internal set; }
        public bool RoyalRouteOpen { get; internal set; }
        public bool SteamEncoded { get; internal set; }
        public SaveAction Action { get; internal set; }
    }

    public static class SaveCodec
    {
        private const int ContainerHeaderSize = 0x40;
        private const int SlotHeaderSize = 0x190;
        private const int PayloadSize = 0x30720;
        private const int MaximumFileSize = 512 * 1024;
        private const int November17 = 230;
        private const int December24 = 267;
        private const int ThirdSemesterStart = 275;
        private const int StoryFlagBase = 0x35e0;
        private const int RoyalRouteFlag = 3186;
        private const int ThirdSemesterFlag = 164;
        private const int FinalDungeonFlag = 1038;
        private const int FieldPosition = 0x13a00;
        private const int DungeonIndex = 0x3e24;
        private const int StoryProgress = 0x3e34;
        private const int CouncillorId = 35;
        private const int ConfidantTable = 0x136a0;
        private const int ConfidantStride = 16;

        // Steam's local save container format is documented by fiber-saveutil.
        private static readonly byte[] Key = Convert.FromBase64String(
            "3lOZS0kYSoOOtkC4c7IDfvNXnxIprUPTlUGVC3yBJF0=");
        private static readonly uint[] CrcTable = CreateCrcTable();

        // Matching flags from two post-battle checkpoints, corroborated by a
        // continuous playthrough from the Depths through the start of January.
        private static readonly int[] SetAfterBattle = {
            127, 171, 379, 2337, 3152, 7347, 7348, 7349, 7350, 7479, 7480,
            8923, 9160, 9161, 9231, 9232, 9244, 9250, 9251, 9257, 9258,
            9260, 9261, 9262, 9263, 9264, 9265, 9266, 9267, 9269, 9270, 9271,
            9302, 9303, 9304, 9305, 9306, 9307, 9308, 9309, 9310, 9311, 9312,
            9313, 9314, 9315, 9316, 9317, 9354, 9355, 9356, 9357, 9379, 9380,
            9443, 9444, 9445, 9446, 9448, 9449, 9450, 9464, 9467, 9468, 9469,
            9470, 9471, 9472, 9473, 9474, 9475, 9476, 9498, 9499, 9501, 9502,
            9503, 9579, 9615, 11205, 11286, 11334, 11405, 11420, 11447, 11931,
            11984, 12725, 12726, 12727, 12746, 12747, 12748
        };
        private static readonly int[] ClearAfterBattle = {
            2338, 2448, 6221, 8795, 8812, 8813, 8814, 8815, 8832, 9645,
            9880, 9881, 9882, 9883, 9884
        };

        private sealed class Save
        {
            public byte[] Header;
            public byte[] Payload;
            public byte[] ContainerFields;
            public uint FileFlags;
        }

        public static SlotInfo Inspect(string path)
        {
            byte[] file = ReadFile(path);
            string hash = Hash(file);
            Save save;
            try { save = Decode(file); }
            catch (InvalidDataException error)
            {
                return new SlotInfo { Hash = hash, FormatError = error.Message };
            }
            int councillor = FindCouncillor(save.Payload);
            return new SlotInfo {
                Hash = hash,
                Title = FirstLine(ReadDescription(save.Header)),
                Day = BitConverter.ToUInt16(save.Header, 4),
                Time = save.Header[6],
                Level = save.Header[9],
                PlayMinutes = (int)(BitConverter.ToUInt32(save.Header, 0) / 1800),
                CouncillorRank = councillor < 0 ? 0 : BitConverter.ToUInt16(save.Payload, councillor + 8),
                RoyalRouteOpen = GetFlag(save.Payload, RoyalRouteFlag),
                SteamEncoded = (save.FileFlags & 0x80000000u) != 0 && (BitConverter.ToUInt32(save.ContainerFields, 12) & 3) == 3,
                Action = Classify(save, councillor)
            };
        }

        public static byte[] BuildResume(string path, string expectedHash)
        {
            byte[] original = ReadFile(path);
            if (Hash(original) != expectedHash)
                throw new InvalidDataException("The source save changed after it was displayed.");
            Save save = Decode(original);
            int councillor = FindCouncillor(save.Payload);
            SaveAction action = Classify(save, councillor);
            switch (action)
            {
                case SaveAction.SkipFinalBattle:
                    MoveToAfterBattle(save);
                    OpenRoyalRoute(save.Payload, councillor);
                    break;
                case SaveAction.AfterBattle:
                case SaveAction.UnlockRoyalRoute:
                    OpenRoyalRoute(save.Payload, councillor);
                    break;
                case SaveAction.PrepareNovember18:
                    SetCouncillorRank(save.Payload, councillor, 9);
                    break;
                default:
                    throw new InvalidDataException("This save is not a supported source.");
            }

            byte[] packed = Encode(save);
            Save verified = Decode(packed);
            if (!BytesEqual(verified.Header, save.Header) || !BytesEqual(verified.Payload, save.Payload))
                throw new InvalidDataException("The rebuilt save did not pass verification.");
            return packed;
        }

        private static void MoveToAfterBattle(Save save)
        {
            // The scripted resume uses save type 3 with no free-roam field.
            save.Header[11] = 3;
            Array.Clear(save.Header, 12, 2);
            UpdateDescription(save.Header);
            Array.Clear(save.Payload, FieldPosition, 0x30);
            SetUInt32(save.Payload, DungeonIndex, 160);
            SetUInt32(save.Payload, StoryProgress, 69);
            SetUInt32(save.Payload, 0x3e3c, 0);
            SetUInt32(save.Payload, 0x3ea4, 0);
            SetUInt32(save.Payload, 0x3eac, 0);

            foreach (int flag in SetAfterBattle) SetFlag(save.Payload, flag, true);
            foreach (int flag in ClearAfterBattle) SetFlag(save.Payload, flag, false);
        }

        private static void OpenRoyalRoute(byte[] data, int councillor)
        {
            // The December 24 evening scheduler checks BIT_CHK(0x10000000 + 114).
            SetFlag(data, RoyalRouteFlag, true);
            SetCouncillorRank(data, councillor, 10);
        }

        private static void SetCouncillorRank(byte[] data, int entry, ushort rank)
        {
            if (BitConverter.ToUInt16(data, entry + 8) == rank) return;
            BitConverter.GetBytes(rank).CopyTo(data, entry + 8);
            Array.Clear(data, entry + 10, 2);
        }

        public static string HashFile(string path)
        {
            return Hash(ReadFile(path));
        }

        private static string Hash(byte[] file)
        {
            using (var hash = SHA256.Create())
                return Convert.ToBase64String(hash.ComputeHash(file));
        }

        private static SaveAction Classify(Save save, int councillor)
        {
            byte[] header = save.Header;
            byte[] data = save.Payload;
            int day = BitConverter.ToUInt16(header, 4);
            int saveType = header[11];
            bool royalFlag = GetFlag(data, RoyalRouteFlag);
            if (saveType == 255) return SaveAction.ClearData;
            if (day > December24 || (day == December24 && header[6] > 4))
            {
                if (royalFlag && GetFlag(data, ThirdSemesterFlag))
                    return day >= ThirdSemesterStart ? SaveAction.ThirdSemester : SaveAction.AlreadyReady;
                return SaveAction.PastBranch;
            }
            if (councillor < 0) return SaveAction.Unavailable;
            if (IsBeforeBattle(save)) return SaveAction.SkipFinalBattle;
            if (IsAfterBattle(save)) return SaveAction.AfterBattle;

            int rank = BitConverter.ToUInt16(data, councillor + 8);
            if (day == November17 && saveType == 0)
            {
                if (rank == 9 || (rank == 10 && royalFlag)) return SaveAction.AlreadyReady;
                return rank == 10 || royalFlag ? SaveAction.UnlockRoyalRoute : SaveAction.PrepareNovember18;
            }

            // These saves reload before the evening scheduler reads the route flag.
            if (day > November17 && day < December24 &&
                (saveType == 0 || saveType == 1 || saveType == 4))
                return royalFlag && rank == 10 ? SaveAction.AlreadyReady : SaveAction.UnlockRoyalRoute;

            return SaveAction.Unavailable;
        }

        private static bool IsBeforeBattle(Save save)
        {
            byte[] header = save.Header;
            byte[] data = save.Payload;
            if (BitConverter.ToUInt16(header, 4) != December24 || header[6] != 4 ||
                (header[11] != 0 && header[11] != 1) || !GetFlag(data, FinalDungeonFlag) ||
                header[13] == 0 ||
                BitConverter.ToUInt16(data, FieldPosition) != header[12] ||
                BitConverter.ToUInt16(data, FieldPosition + 2) != header[13] ||
                BitConverter.ToUInt32(data, DungeonIndex) != header[12])
                return false;

            uint progress = BitConverter.ToUInt32(data, StoryProgress);
            return (header[12] == 161 && progress >= 61 && progress <= 62)
                || (header[12] == 160 && progress >= 63 && progress <= 68);
        }

        private static bool IsAfterBattle(Save save)
        {
            byte[] header = save.Header;
            byte[] data = save.Payload;
            return BitConverter.ToUInt16(header, 4) == December24 && header[6] == 4 &&
                header[11] == 3 && header[12] == 0 && header[13] == 0 &&
                GetFlag(data, FinalDungeonFlag) && BitConverter.ToUInt32(data, FieldPosition) == 0 &&
                BitConverter.ToUInt32(data, DungeonIndex) == 160 &&
                BitConverter.ToUInt32(data, StoryProgress) == 69;
        }

        private static int FindCouncillor(byte[] data)
        {
            int found = -1;
            for (int i = 0; i < 23; i++)
            {
                int entry = ConfidantTable + i * ConfidantStride;
                if (BitConverter.ToUInt16(data, entry + 6) != CouncillorId) continue;
                int rank = BitConverter.ToUInt16(data, entry + 8);
                if (found >= 0 || rank < 1 || rank > 10) return -1;
                found = entry;
            }
            return found;
        }

        private static string ReadDescription(byte[] header)
        {
            const int offset = 0x90;
            int end = Array.IndexOf<byte>(header, 0, offset, 0x100);
            return Encoding.UTF8.GetString(header, offset, (end < 0 ? header.Length : end) - offset);
        }

        private static string FirstLine(string description)
        {
            var line = new StringBuilder();
            foreach (char value in description)
            {
                if (value == '\r' || value == '\n') break;
                if (!char.IsControl(value) && char.GetUnicodeCategory(value) != UnicodeCategory.Format)
                    line.Append(value);
            }
            return line.ToString().Trim();
        }

        private static void UpdateDescription(byte[] header)
        {
            const int DescriptionOffset = 0x90;
            const int DescriptionSize = 0x100;
            string description = ReadDescription(header);
            int newline = description.IndexOf('\n');
            string suffix = newline < 0 ? "" : description.Substring(newline);
            string title = header[15] == 9
                ? "12\u670824\u65e5 \u6da9\u8c37\u7ad9\u524d\u5e7f\u573a" : "12/24 Shibuya Station Square";
            byte[] updated = Encoding.UTF8.GetBytes(title + suffix);
            if (updated.Length >= DescriptionSize) updated = Encoding.UTF8.GetBytes(title + "\n");
            Array.Clear(header, DescriptionOffset, DescriptionSize);
            Buffer.BlockCopy(updated, 0, header, DescriptionOffset, updated.Length);
        }

        private static byte[] ReadFile(string path)
        {
            using (FileStream file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (file.Length > MaximumFileSize)
                    throw new InvalidDataException("The file exceeds the size of a supported P5R save.");
                using (var reader = new BinaryReader(file))
                    return reader.ReadBytes((int)file.Length);
            }
        }

        private static Save Decode(byte[] file)
        {
            if (file.Length < ContainerHeaderSize ||
                file[0] != 'D' || file[1] != 'A' || file[2] != 'T' || file[3] != 'A' ||
                BitConverter.ToUInt32(file, 4) != Crc(file, 8))
                throw new InvalidDataException("Invalid PC save container or checksum.");

            uint fileFlags = BitConverter.ToUInt32(file, 12);
            bool encrypted = (fileFlags & 0x80000000u) != 0;
            if (encrypted && (file.Length & 15) != 0)
                throw new InvalidDataException("Invalid encrypted save length.");
            byte[] body = encrypted ? Transform(file, 0x20, Slice(file, 0x10, 16), false)
                : Slice(file, 0x20, file.Length - 0x20);
            byte[] fields = Slice(body, 0, 0x20);
            uint sectionFlags = BitConverter.ToUInt32(fields, 12);
            bool compressedHeader = (sectionFlags & 1) != 0;
            bool compressedData = (sectionFlags & 2) != 0;
            int headerEnd = BitConverter.ToUInt16(fields, compressedHeader ? 2 : 0) - 0x20;
            int dataStart = Align16(headerEnd);
            uint dataLength = compressedData ? BitConverter.ToUInt32(fields, 8) : PayloadSize;
            if (BitConverter.ToUInt16(fields, 0) != ContainerHeaderSize + SlotHeaderSize ||
                BitConverter.ToUInt32(fields, 4) != PayloadSize ||
                headerEnd <= 0x20 || dataStart > body.Length || dataLength == 0 ||
                dataLength > body.Length - dataStart)
                throw new InvalidDataException("Unsupported Steam save layout.");

            byte[] header = compressedHeader ? Inflate(body, 0x20, headerEnd - 0x20, SlotHeaderSize)
                : Slice(body, 0x20, SlotHeaderSize);
            byte[] data = compressedData ? Inflate(body, dataStart, (int)dataLength, PayloadSize)
                : Slice(body, dataStart, PayloadSize);
            if (BitConverter.ToUInt32(data, 0) != 0x31 || BitConverter.ToUInt32(fields, 16) != Crc(data, 0))
                throw new InvalidDataException("Unsupported save payload or checksum.");
            return new Save { Header = header, Payload = data, FileFlags = fileFlags, ContainerFields = fields };
        }

        private static byte[] Encode(Save save)
        {
            byte[] header = Deflate(save.Header);
            byte[] data = Deflate(save.Payload);
            int dataStart = Align16(0x20 + header.Length);
            byte[] body = new byte[dataStart + Align16(data.Length)];
            save.ContainerFields.CopyTo(body, 0);
            BitConverter.GetBytes((ushort)(ContainerHeaderSize + header.Length)).CopyTo(body, 2);
            SetUInt32(body, 8, (uint)data.Length);
            SetUInt32(body, 12, BitConverter.ToUInt32(save.ContainerFields, 12) | 3);
            SetUInt32(body, 16, Crc(save.Payload, 0));
            header.CopyTo(body, 0x20);
            data.CopyTo(body, dataStart);

            byte[] iv = new byte[16];
            using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(iv);
            byte[] file = new byte[0x20 + body.Length];
            Encoding.ASCII.GetBytes("DATA").CopyTo(file, 0);
            uint seconds = (uint)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            SetUInt32(file, 8, seconds);
            SetUInt32(file, 12, save.FileFlags | 0x80000000u);
            iv.CopyTo(file, 16);
            Transform(body, 0, iv, true).CopyTo(file, 0x20);
            SetUInt32(file, 4, Crc(file, 8));
            return file;
        }

        private static byte[] Transform(byte[] input, int offset, byte[] iv, bool encrypt)
        {
            using (Aes aes = Aes.Create())
            {
                aes.Mode = CipherMode.CBC;
                aes.Padding = PaddingMode.None;
                using (ICryptoTransform transform = encrypt ? aes.CreateEncryptor(Key, iv) : aes.CreateDecryptor(Key, iv))
                    return transform.TransformFinalBlock(input, offset, input.Length - offset);
            }
        }

        // DeflateStream uses raw DEFLATE on both .NET Framework and modern .NET.
        // Add or verify the zlib wrapper explicitly for Windows PowerShell 5.1.
        private static byte[] Inflate(byte[] bytes, int start, int length, int expectedSize)
        {
            if (length < 6 || bytes[start] != 0x78 || (bytes[start + 1] & 0x20) != 0 ||
                ((bytes[start] << 8) + bytes[start + 1]) % 31 != 0)
                throw new InvalidDataException("Invalid zlib header.");
            byte[] raw = new byte[expectedSize];
            using (var input = new MemoryStream(bytes, start + 2, length - 6, false))
            using (var deflate = new DeflateStream(input, CompressionMode.Decompress))
            {
                int total = 0;
                while (total < raw.Length)
                {
                    int count = deflate.Read(raw, total, raw.Length - total);
                    if (count == 0) throw new InvalidDataException("Short compressed save section.");
                    total += count;
                }
                if (deflate.ReadByte() != -1) throw new InvalidDataException("Oversize compressed save section.");
            }
            int trailer = start + length - 4;
            uint adler = Adler32(raw);
            for (int i = 0; i < 4; i++)
            {
                if (bytes[trailer + i] != (byte)(adler >> (24 - i * 8)))
                    throw new InvalidDataException("Invalid zlib checksum.");
            }
            return raw;
        }

        private static byte[] Deflate(byte[] raw)
        {
            using (var output = new MemoryStream())
            {
                output.WriteByte(0x78);
                output.WriteByte(0x9c);
                using (var deflate = new DeflateStream(output, CompressionLevel.Optimal, true))
                    deflate.Write(raw, 0, raw.Length);
                uint adler = Adler32(raw);
                for (int i = 3; i >= 0; i--) output.WriteByte((byte)(adler >> (i * 8)));
                return output.ToArray();
            }
        }

        private static uint Adler32(byte[] bytes)
        {
            uint a = 1, b = 0;
            foreach (byte value in bytes)
            {
                a = (a + value) % 65521;
                b = (b + a) % 65521;
            }
            return (b << 16) | a;
        }

        private static uint[] CreateCrcTable()
        {
            uint[] table = new uint[256];
            for (int i = 0; i < table.Length; i++)
            {
                uint value = (uint)i << 24;
                for (int bit = 0; bit < 8; bit++)
                    value = (value << 1) ^ ((value & 0x80000000u) == 0 ? 0u : 0x04c11db7u);
                table[i] = value;
            }
            return table;
        }

        private static uint Crc(byte[] bytes, int start)
        {
            uint crc = 0xffffffffu;
            for (int i = start; i < bytes.Length; i++)
                crc = (crc << 8) ^ CrcTable[bytes[i] ^ (crc >> 24)];
            return crc;
        }

        private static byte[] Slice(byte[] bytes, int start, int length)
        {
            byte[] result = new byte[length];
            Buffer.BlockCopy(bytes, start, result, 0, length);
            return result;
        }
        private static int Align16(int size) { return (size + 15) & ~15; }
        private static void SetUInt32(byte[] data, int offset, uint value) { BitConverter.GetBytes(value).CopyTo(data, offset); }
        private static bool GetFlag(byte[] data, int id) { return (data[StoryFlagBase + id / 8] & (1 << (id % 8))) != 0; }

        private static void SetFlag(byte[] bytes, int id, bool value)
        {
            int offset = StoryFlagBase + id / 8;
            int mask = 1 << (id % 8);
            bytes[offset] = (byte)(value ? bytes[offset] | mask : bytes[offset] & ~mask);
        }

        private static bool BytesEqual(byte[] first, byte[] second)
        {
            if (first.Length != second.Length) return false;
            for (int i = 0; i < first.Length; i++)
                if (first[i] != second[i]) return false;
            return true;
        }
    }
}
'@
}

function Read-ResumeChoice {
    param([string] $Prompt, [int[]] $Numbers, [int] $Default, [string[]] $Extras)

    while ($true) {
        $reply = Read-Host $Prompt
        if ($null -eq $reply) { return }
        $answer = $reply.Trim()
        if ($answer -eq 'Q') { return }
        if (-not $answer -and $Default) { return $Default }
        if ($answer -and $answer -in $Extras) { return $answer.ToUpperInvariant() }
        $number = 0
        if ([int]::TryParse($answer, [ref] $number) -and $number -in $Numbers) { return $number }
        Write-Host '请输入显示的编号或选项。'
    }
}

function Get-PastedPath {
    param([string] $Value)

    $path = $Value.Trim()
    if ($path.Length -ge 2 -and
        (($path.StartsWith('"') -and $path.EndsWith('"')) -or
         ($path.StartsWith("'") -and $path.EndsWith("'")))) {
        $path = $path.Substring(1, $path.Length - 2)
    }
    [Environment]::ExpandEnvironmentVariables($path)
}

function Find-SteamProfiles {
    param([string] $SteamFolder)

    foreach ($profile in (Get-ChildItem -LiteralPath $SteamFolder -Directory -Force | Sort-Object Name)) {
        if ($profile.Name -notmatch '^\d{17}$') { continue }
        $savedata = Join-Path $profile.FullName 'savedata'
        if ([IO.Directory]::Exists($savedata)) { $savedata }
    }
}

function Resolve-ResumeDirectories {
    param([string] $Path)

    try { $item = Get-Item -LiteralPath (Get-PastedPath $Path) -Force }
    catch { throw '无法打开这个路径。请检查路径和访问权限。' }
    if (-not $item.PSIsContainer) {
        if ($item.Name -ine 'DATA.DAT' -or $item.Directory.Name -notmatch '^DATA(0[1-9]|1[0-6])$') {
            throw '请选择目标存档目录。可以用 F 单独选择源存档文件。'
        }
        $item = $item.Directory.Parent
    } elseif ($item.Name -match '^DATA(0[1-9]|1[0-6])$' -and $item.Parent) {
        $item = $item.Parent
    }
    if (-not $item.Parent) { throw '请选择包含存档槽的子文件夹。' }

    if ([IO.File]::Exists((Join-Path $item.FullName 'P5R.exe')) -or
        [IO.File]::Exists((Join-Path $item.FullName 'steam.exe'))) {
        throw '这个路径是安装目录。请选实际的存档目录，通常在 %APPDATA%\SEGA\P5R\Steam。'
    }
    $savedata = Join-Path $item.FullName 'savedata'
    if ([IO.Directory]::Exists($savedata)) { return $savedata }
    if ($item.Name -ieq 'savedata' -or [IO.File]::Exists((Join-Path $item.FullName 'SYSTEM\SYSTEM.DAT'))) {
        return $item.FullName
    }
    foreach ($number in 1..16) {
        if ([IO.File]::Exists((Join-Path $item.FullName ('DATA{0:00}\DATA.DAT' -f $number)))) {
            return $item.FullName
        }
    }
    if ($item.Name -ieq 'Steam') { return (Find-SteamProfiles $item.FullName) }
    $steam = Join-Path $item.FullName 'Steam'
    if ([IO.Directory]::Exists($steam)) { return (Find-SteamProfiles $steam) }
    throw '这里找不到 P5R 的编号槽。请选 savedata、它的上级目录，或某个槽里的 DATA.DAT。'
}

function Select-ResumeDirectory {
    param([string] $InitialPath, [switch] $Manual)

    $directories = @()
    if ($InitialPath) {
        try { $directories = @(Resolve-ResumeDirectories $InitialPath) }
        catch { Write-Host $_.Exception.Message }
    } elseif (-not $Manual) {
        $appData = [Environment]::GetFolderPath('ApplicationData')
        if ($appData) {
            $steamFolder = Join-Path $appData 'SEGA\P5R\Steam'
            if ([IO.Directory]::Exists($steamFolder)) {
                try { $directories = @(Find-SteamProfiles $steamFolder) }
                catch { Write-Verbose $_.Exception.Message }
            }
        }
    }
    if (-not $directories.Count -and -not $Manual) {
        Write-Host '没找到默认的 Steam 存档目录。游戏可以装在任意磁盘，工具只需要存档目录。'
        Write-Host '如果是第一次玩，请先在游戏里手动存一次档。已有备份的话，可以输入备份的存档目录。'
    }
    while ($true) {
        if ($directories.Count -eq 1) { return $directories[0] }
        if ($directories.Count -gt 1) {
            Write-Host '找到多个 Steam 存档目录'
            for ($i = 0; $i -lt $directories.Count; $i++) {
                Write-Host ('[{0}] {1}' -f ($i + 1), $directories[$i])
            }
            $choice = Read-ResumeChoice '选目录 [P 手动输入，Q 退出]' (1..($directories.Count)) -Extras 'P'
            if (-not $choice) { return }
            if ($choice -ne 'P') { return $directories[$choice - 1] }
        }
        $path = Read-Host '输入存档目录 [Q 退出]'
        if (-not $path -or $path.Trim() -eq 'Q') { return }
        try {
            $directories = @(Resolve-ResumeDirectories $path)
            if (-not $directories.Count) { Write-Host '这个 Steam 目录还没有 P5R 存档。' }
        } catch {
            Write-Host $_.Exception.Message
            $directories = @()
        }
    }
}

function Get-ResumeSlots {
    param([string] $Root)

    foreach ($number in 1..16) {
        $file = Join-Path $Root ('DATA{0:00}\DATA.DAT' -f $number)
        $status = 'Read'
        $info = $null
        try {
            $item = Get-Item -LiteralPath $file -Force
            if ($item.PSIsContainer) { throw 'A directory is using the save file name.' }
            $info = [P5RRoyalResume.V2.SaveCodec]::Inspect($item.FullName)
        } catch [System.Management.Automation.ItemNotFoundException] {
            $status = 'Empty'
        } catch {
            $status = 'Blocked'
            Write-Verbose ('无法读取 {0} 号槽。{1}' -f $number, $_.Exception.GetBaseException().Message)
        }
        [pscustomobject] @{ Number = $number; File = $file; Info = $info; Status = $status }
    }
}

function Format-ResumeSlot {
    param($Slot)

    if ($Slot.Status -eq 'Empty') { return '空槽' }
    if ($Slot.Status -eq 'Blocked') { return '读不了，无法安全覆盖' }
    $info = $Slot.Info
    if ($info.FormatError) { return '格式不支持或档案损坏' }
    $date = [datetime]::new(2016, 4, 1).AddDays($info.Day).ToString('MM/dd')
    $title = switch ([string] $info.Action) {
        'AfterBattle' { '12/24 涩谷站前广场（最终战后）' }
        'ClearData' { "$date 通关存档" }
        default {
            if ($info.Title) { $info.Title }
            else {
                $times = @('早晨', '上午', '午休', '下午', '放学后', '夜晚', '深夜')
                $time = if ($info.Time -lt $times.Count) { $times[$info.Time] } else { '时段未知' }
                "$date $time"
            }
        }
    }
    '{0}  |  Lv.{1}  |  游玩 {2}:{3:00}' -f $title, $info.Level, [int] [Math]::Floor($info.PlayMinutes / 60), ($info.PlayMinutes % 60)
}

function Get-ResumeActionText {
    param($Info)

    switch ([string] $Info.Action) {
        'SkipFinalBattle' { '跳到最终战后，开启皇家线' }
        'AfterBattle' {
            if ($Info.RoyalRouteOpen -and $Info.CouncillorRank -eq 10) { '战后继续，皇家线已开启' }
            else { '从战后开启皇家线' }
        }
        'PrepareNovember18' { '丸喜升到 Coop 9，等 11/18 正常触发' }
        'UnlockRoyalRoute' { '补开皇家线，保持当前日期和进度' }
        'AlreadyReady' { '条件已满足，可以直接读取这个档' }
        'ThirdSemester' { '已在第三学期，可以直接读取这个档' }
        'ClearData' { '通关存档用于二周目，请选择分岔前的手动档' }
        'PastBranch' { '已过 12/24 分岔，请选择更早的存档' }
        default { '请选择 11/17 起的可用档，或 12/24 最终战区域和战后存档点的档' }
    }
}

function Test-ResumeSource {
    param($Slot)

    $Slot.Status -eq 'Read' -and -not $Slot.Info.FormatError -and
        [string] $Slot.Info.Action -in @('SkipFinalBattle', 'AfterBattle', 'PrepareNovember18', 'UnlockRoyalRoute')
}

function Select-ResumeSource {
    param($Slots)

    Write-Host '要跳过重复战斗，请选 12/24 印象空间最底层、通往最终 Boss 的区域，或涩谷站前广场的战后档。'
    Write-Host '11/17 到 12/23 的可用档可以补开皇家线，仍从原日期继续。'
    $available = @($Slots | Where-Object { Test-ResumeSource $_ } |
        Sort-Object -Property @{ Expression = { $_.Info.Day }; Descending = $true },
            @{ Expression = { [string] $_.Info.Action -eq 'AfterBattle' }; Descending = $true },
            @{ Expression = { $_.Info.PlayMinutes }; Descending = $true }, Number)
    if ($available.Count) {
        Write-Host '可用源档'
        foreach ($slot in $available) {
            Write-Host ('[{0:00}] {1}  |  {2}' -f $slot.Number, (Format-ResumeSlot $slot), (Get-ResumeActionText $slot.Info))
        }
    } else {
        Write-Host '这个目录里没有可用源档。可以选备份文件或换一个存档目录。'
        foreach ($slot in $Slots | Where-Object { $_.Status -ne 'Empty' }) {
            $text = Format-ResumeSlot $slot
            if ($slot.Info -and -not $slot.Info.FormatError) { $text += '  |  ' + (Get-ResumeActionText $slot.Info) }
            Write-Host ('[{0:00}] {1}' -f $slot.Number, $text)
        }
    }
    $defaultSource = if ($available.Count) { $available[0].Number } else { 0 }
    $prompt = if ($defaultSource) {
        '输入源档左侧方括号里的编号（回车选 [{0:00}]，F 选文件，P 换目录，Q 退出）' -f $defaultSource
    }
        else { '选源档 [F 选文件，P 换目录，Q 退出]' }
    while ($true) {
        $choice = Read-ResumeChoice $prompt (1..16) $defaultSource @('F', 'P')
        if (-not $choice) { return }
        if ($choice -eq 'P') { return 'P' }
        if ($choice -eq 'F') {
            $path = Read-Host '输入源文件路径 [回车返回]'
            if (-not $path) { continue }
            try {
                $item = Get-Item -LiteralPath (Get-PastedPath $path) -Force
                if ($item.PSIsContainer) { throw 'Please select a file.' }
                $source = [pscustomobject] @{ Number = $null; File = $item.FullName
                    Info = [P5RRoyalResume.V2.SaveCodec]::Inspect($item.FullName); Status = 'Read' }
            } catch {
                Write-Host '无法读取这个文件。请选存档文件本身，例如 DATA.DAT。'
                continue
            }
        } else {
            $source = $Slots[$choice - 1]
        }
        if (Test-ResumeSource $source) { return $source }
        if ($source.Info -and -not $source.Info.FormatError) { Write-Host (Get-ResumeActionText $source.Info) }
        else { Write-Host (Format-ResumeSlot $source) }
    }
}

function Assert-GameClosed {
    if (Get-Process -Name 'P5R' -ErrorAction SilentlyContinue) {
        throw 'P5R 还在运行。请退出游戏后重新运行工具，避免游戏覆盖存档。'
    }
}

function Get-SlotHash {
    param([string] $Path)

    if ([IO.File]::Exists($Path)) { [P5RRoyalResume.V2.SaveCodec]::HashFile($Path) }
}

function Set-ResumeSlot {
    param([string] $Root, $Source, $Target)

    Assert-GameClosed
    $sourceHash = $Source.Info.Hash
    $targetHash = if ($Target.Info) { $Target.Info.Hash }
    $profileRoot = (Get-Item -LiteralPath $Root).Parent.FullName
    $lockFile = Join-Path $profileRoot '.p5r-royal-resume.lock'
    try {
        $lock = [IO.FileStream]::new($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    } catch {
        throw '无法锁定存档目录。请检查写入权限，并关闭其他正在使用此目录的续档工具。'
    }
    try {
        if ((Get-SlotHash $Source.File) -cne $sourceHash -or (Get-SlotHash $Target.File) -cne $targetHash) {
            throw '源档或目标槽在显示后发生了变化。请重新运行，确认最新内容。'
        }
        $candidate = [P5RRoyalResume.V2.SaveCodec]::BuildResume($Source.File, $sourceHash)
        $targetFolder = Split-Path -Parent $Target.File
        [void] [IO.Directory]::CreateDirectory($targetFolder)
        $stage = Join-Path $targetFolder ('.p5r-royal-resume-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllBytes($stage, $candidate)
            $stageHash = Get-SlotHash $stage
            Assert-GameClosed
            if ((Get-SlotHash $Source.File) -cne $sourceHash -or (Get-SlotHash $Target.File) -cne $targetHash) {
                throw '源档或目标槽在显示后发生了变化。请重新运行，确认最新内容。'
            }
            if ($targetHash) {
                $backupFolder = Join-Path $profileRoot 'p5r-royal-resume-backups'
                [void] [IO.Directory]::CreateDirectory($backupFolder)
                $backup = Join-Path $backupFolder ('{0:yyyyMMdd-HHmmss}-{1}-DATA{2:00}.DAT' -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0, 8)), $Target.Number)
                [IO.File]::Replace($stage, $Target.File, $backup)
                Write-Host "备份 $backup"
            } else {
                [IO.File]::Move($stage, $Target.File)
            }
            if ((Get-SlotHash $Target.File) -cne $stageHash) { throw '写入后校验失败。请检查目标槽和备份。' }
        } finally {
            if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        }
    } finally {
        $lock.Dispose()
    }
}

function Invoke-RoyalResume {
    Write-Host 'P5R 皇家版续档'
    $root = Select-ResumeDirectory -InitialPath $SaveDirectory
    while ($root) {
        Write-Host "存档目录 $root"
        $slots = @(Get-ResumeSlots $root)
        $source = Select-ResumeSource $slots
        if (-not $source) { return }
        if ($source -ne 'P') { break }
        $root = Select-ResumeDirectory -Manual
    }
    if (-not $root) { return }

    # Re-read before showing the targets so the labels and write checks use the same snapshot.
    $targets = @(Get-ResumeSlots $root)
    Write-Host '目标槽（已有档会备份）'
    foreach ($slot in $targets) {
        Write-Host ('[{0:00}] {1}' -f $slot.Number, (Format-ResumeSlot $slot))
    }
    $choices = @($targets | Where-Object { $_.Status -ne 'Blocked' })
    if (-not $choices.Count) { throw '这个目录的槽都无法安全写入。请检查访问权限。' }
    $empty = $choices | Where-Object { $_.Status -eq 'Empty' } | Select-Object -First 1
    $prompt = if ($empty) { "选目标槽 [回车选空槽 $($empty.Number)，Q 退出]" } else { '选要备份并替换的槽 [Q 退出]' }
    $targetNumber = Read-ResumeChoice $prompt $choices.Number $empty.Number
    if (-not $targetNumber) { return }
    $target = $targets[$targetNumber - 1]
    if ($source.File -ieq $target.File -and [string] $source.Info.Action -eq 'AfterBattle' -and
        $source.Info.SteamEncoded -and $source.Info.RoyalRouteOpen -and $source.Info.CouncillorRank -eq 10) {
        Write-Host '这个槽已是可用的皇家线战后档，可以直接读取。'
        return
    }
    $sourceName = if ($source.Number) { "$($source.Number) 号槽" } else { [IO.Path]::GetFileName($source.File) }
    Write-Host ('源档 {0}  |  {1}' -f $sourceName, (Get-ResumeActionText $source.Info))
    Write-Host ('目标 [{0:00}] {1}' -f $targetNumber, (Format-ResumeSlot $target))
    if (([string] (Read-Host '应用改动 [y/N]')).Trim() -ne 'y') { Write-Host '已取消。'; return }

    Set-ResumeSlot $root $source $target
    if ([string] $source.Info.Action -in @('SkipFinalBattle', 'AfterBattle')) {
        Write-Host ("已写入 {0} 号槽。读取该档，从 12 月 24 日晚的涩谷站前广场继续。" -f $targetNumber)
    } else {
        Write-Host ("已写入 {0} 号槽。读取该档，从原日期继续。" -f $targetNumber)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-RoyalResume }
    catch { throw $_.Exception.GetBaseException().Message }
}
