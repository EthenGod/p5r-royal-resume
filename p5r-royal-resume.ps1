#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $SaveDirectory
)

$ErrorActionPreference = 'Stop'

if (-not ('P5RRoyalResume.V1.SaveCodec' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace P5RRoyalResume.V1
{
    public sealed class SlotInfo
    {
        public int Day { get; internal set; }
        public int Level { get; internal set; }
        public int PlayMinutes { get; internal set; }
        public int Field { get; internal set; }
        public bool IsClearData { get; internal set; }
        public bool CanResume { get; internal set; }
    }

    public static class SaveCodec
    {
        private const int ContainerHeaderSize = 0x40;
        private const int SlotHeaderSize = 0x190;
        private const int PayloadSize = 0x30720;
        private const int MaximumFileSize = 512 * 1024;
        private const int December24 = 267;
        private const int StoryFlagBase = 0x35e0;
        private const int RoyalRouteFlag = 3186;
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
            Save save = Decode(ReadFile(path));
            return new SlotInfo {
                Day = BitConverter.ToUInt16(save.Header, 4),
                Level = save.Header[9],
                PlayMinutes = (int)(BitConverter.ToUInt32(save.Header, 0) / 1800),
                Field = save.Header[12],
                IsClearData = save.Header[11] == 255,
                CanResume = IsSourceCheckpoint(save) && FindCouncillor(save.Payload) >= 0
            };
        }

        public static byte[] BuildResume(string path)
        {
            Save save = Decode(ReadFile(path));
            int councillor = FindCouncillor(save.Payload);
            if (!IsSourceCheckpoint(save) || councillor < 0)
                throw new InvalidDataException("The selected save is not a supported December 24 checkpoint.");

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
            // The December 24 evening scheduler checks BIT_CHK(0x10000000 + 114).
            SetFlag(save.Payload, RoyalRouteFlag, true);
            if (BitConverter.ToUInt16(save.Payload, councillor + 8) != 10)
            {
                save.Payload[councillor + 8] = 10;
                save.Payload[councillor + 9] = 0;
                Array.Clear(save.Payload, councillor + 10, 2);
            }

            byte[] packed = Encode(save);
            Save verified = Decode(packed);
            if (!BytesEqual(verified.Header, save.Header) || !BytesEqual(verified.Payload, save.Payload))
                throw new InvalidDataException("The rebuilt save did not pass verification.");
            return packed;
        }

        public static string HashFile(string path)
        {
            using (var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var hash = SHA256.Create())
                return Convert.ToBase64String(hash.ComputeHash(file));
        }

        private static bool IsSourceCheckpoint(Save save)
        {
            byte[] header = save.Header;
            byte[] data = save.Payload;
            if (BitConverter.ToUInt16(header, 4) != December24 || header[6] != 4 ||
                header[11] != 0 || !GetFlag(data, FinalDungeonFlag) ||
                BitConverter.ToUInt16(data, FieldPosition) != header[12] ||
                BitConverter.ToUInt16(data, FieldPosition + 2) != header[13] ||
                BitConverter.ToUInt32(data, DungeonIndex) != header[12])
                return false;

            uint progress = BitConverter.ToUInt32(data, StoryProgress);
            return (header[12] == 161 && header[13] == 51 && progress == 61)
                || (header[12] == 160 && header[13] == 6 && progress == 68);
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

        private static void UpdateDescription(byte[] header)
        {
            const int DescriptionOffset = 0x90;
            const int DescriptionSize = 0x100;
            int end = Array.IndexOf<byte>(header, 0, DescriptionOffset);
            if (end < 0) end = header.Length;
            string description = Encoding.UTF8.GetString(header, DescriptionOffset, end - DescriptionOffset);
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
                if (file.Length < ContainerHeaderSize || file.Length > MaximumFileSize)
                    throw new InvalidDataException("Invalid save file size.");
                using (var reader = new BinaryReader(file))
                    return reader.ReadBytes((int)file.Length);
            }
        }

        private static Save Decode(byte[] file)
        {
            uint fileFlags = BitConverter.ToUInt32(file, 12);
            if (file[0] != 'D' || file[1] != 'A' || file[2] != 'T' || file[3] != 'A' ||
                (fileFlags & 0x80000000u) == 0 || (file.Length & 15) != 0 ||
                BitConverter.ToUInt32(file, 4) != Crc(file, 8))
                throw new InvalidDataException("Invalid Steam save container or checksum.");

            byte[] body = Transform(file, 0x20, Slice(file, 0x10, 16), false);
            byte[] fields = Slice(body, 0, 0x20);
            int headerEnd = BitConverter.ToUInt16(fields, 2) - 0x20;
            int dataStart = Align16(headerEnd);
            uint dataLength = BitConverter.ToUInt32(fields, 8);
            if ((BitConverter.ToUInt32(fields, 12) & 3) != 3 ||
                BitConverter.ToUInt16(fields, 0) != ContainerHeaderSize + SlotHeaderSize ||
                BitConverter.ToUInt32(fields, 4) != PayloadSize ||
                headerEnd <= 0x20 || dataStart > body.Length || dataLength == 0 ||
                dataLength > body.Length - dataStart)
                throw new InvalidDataException("Unsupported Steam save layout.");

            byte[] header = Inflate(body, 0x20, headerEnd - 0x20, SlotHeaderSize);
            byte[] data = Inflate(body, dataStart, (int)dataLength, PayloadSize);
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
            SetUInt32(body, 16, Crc(save.Payload, 0));
            header.CopyTo(body, 0x20);
            data.CopyTo(body, dataStart);

            byte[] iv = new byte[16];
            using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(iv);
            byte[] file = new byte[0x20 + body.Length];
            Encoding.ASCII.GetBytes("DATA").CopyTo(file, 0);
            uint seconds = (uint)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            SetUInt32(file, 8, seconds);
            SetUInt32(file, 12, save.FileFlags);
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

function Read-SlotNumber {
    param([string] $Prompt, [int[]] $Allowed, [int] $Default)

    while ($true) {
        $label = if ($Default) { "$Prompt [$Default，Q 退出]" } else { "$Prompt [Q 退出]" }
        $reply = Read-Host $label
        if ($null -eq $reply) { return }
        $answer = $reply.Trim()
        if ($answer -eq 'Q') { return }
        if (-not $answer -and $Default) { return $Default }
        $number = 0
        if ([int]::TryParse($answer, [ref] $number) -and $number -in $Allowed) { return $number }
        Write-Host '请输入列表里的编号。'
    }
}

function Assert-GameClosed {
    if (Get-Process -Name 'P5R' -ErrorAction SilentlyContinue) {
        throw '请退出 P5R，再运行这条命令。'
    }
}

function Get-SlotHash {
    param([string] $Path)

    if ([IO.File]::Exists($Path)) { [P5RRoyalResume.V1.SaveCodec]::HashFile($Path) }
}

function Invoke-RoyalResume {
    Assert-GameClosed

    Write-Host 'P5R 皇家版续档'
    if ($SaveDirectory) {
        $root = (Get-Item -LiteralPath $SaveDirectory).FullName
    } else {
        $steamRoot = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'SEGA\P5R\Steam'
        if (-not (Test-Path -LiteralPath $steamRoot -PathType Container)) {
            throw '找不到 Windows Steam 版 P5R 的存档。'
        }
        $profiles = @(Get-ChildItem -LiteralPath $steamRoot -Directory |
            Where-Object { $_.Name -match '^\d{17}$' -and [IO.Directory]::Exists((Join-Path $_.FullName 'savedata')) })
        if ($profiles.Count -eq 0) { throw '找不到 Steam 存档槽。' }
        $profileIndex = 1
        if ($profiles.Count -gt 1) {
            for ($i = 0; $i -lt $profiles.Count; $i++) { Write-Host ('[{0}] Steam ID {1}' -f ($i + 1), $profiles[$i].Name) }
            $profileIndex = Read-SlotNumber '选 Steam 存档' (1..($profiles.Count))
            if (-not $profileIndex) { return }
        }
        $root = Join-Path $profiles[$profileIndex - 1].FullName 'savedata'
    }

    if (-not [IO.Directory]::Exists($root)) { throw '存档路径需要是文件夹。' }
    $slots = @(1..16 | ForEach-Object {
        $number = $_
        $file = Join-Path $root ('DATA{0:00}\DATA.DAT' -f $number)
        $info = $null
        $exists = [IO.File]::Exists($file)
        if ($exists) {
            try { $info = [P5RRoyalResume.V1.SaveCodec]::Inspect($file) }
            catch { Write-Verbose ("读取 {0} 号槽失败。{1}" -f $number, $_.Exception.GetBaseException().Message) }
        }
        [pscustomobject] @{ Number = $number; File = $file; Info = $info; Exists = $exists }
    })
    $sources = @($slots | Where-Object { $_.Info -and $_.Info.CanResume } |
        Sort-Object -Property { $_.Info.PlayMinutes } -Descending)
    if ($sources.Count -eq 0) {
        throw '没有找到可用的源存档。需要 12 月 24 日的印象空间最底层安全屋或最终 Boss 前的档。'
    }
    Write-Host '可用的源存档'
    foreach ($slot in $sources) {
        $location = if ($slot.Info.Field -eq 161) { '印象空间最底层' } else { '最终 Boss 前' }
        Write-Host ('[{0:00}] 12/24 {1}  Lv.{2}' -f $slot.Number, $location, $slot.Info.Level)
    }
    $sourceNumber = Read-SlotNumber '选源槽' $sources.Number $sources[0].Number
    if (-not $sourceNumber) { return }
    $source = $slots[$sourceNumber - 1]
    $sourceHash = Get-SlotHash $source.File
    if (-not $sourceHash) { throw '源存档已移走。请重新运行。' }

    $empty = @($slots | Where-Object { -not $_.Exists } | Select-Object -ExpandProperty Number)
    if ($empty.Count) { Write-Host ('空槽 {0}' -f ($empty -join '、')) }
    else { Write-Host '16 个槽都已有存档。选中后会先备份原档。' }
    $defaultTarget = if ($empty.Count) { $empty[0] } else { 0 }
    $targetNumber = Read-SlotNumber '选目标槽（1–16）' (1..16) $defaultTarget
    if (-not $targetNumber) { return }
    $target = $slots[$targetNumber - 1]
    $targetHash = Get-SlotHash $target.File
    $action = if ($targetHash) { '备份并替换' } else { '写入' }
    Write-Host ('从 {0} 号槽制作 12 月 24 日晚的皇家版续档，{1} {2} 号槽。' -f $sourceNumber, $action, $targetNumber)
    if (([string] (Read-Host '应用改动 [y/N]')).Trim() -ne 'y') { Write-Host '已取消。'; return }

    $profileRoot = (Get-Item -LiteralPath $root).Parent.FullName
    $lockFile = Join-Path $profileRoot '.p5r-royal-resume.lock'
    $lock = [IO.FileStream]::new($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    try {
        Assert-GameClosed
        if ((Get-SlotHash $source.File) -ne $sourceHash -or (Get-SlotHash $target.File) -ne $targetHash) {
            throw '存档在选择后发生了变化。请重新运行。'
        }
        $candidate = [P5RRoyalResume.V1.SaveCodec]::BuildResume($source.File)
        $targetFolder = Split-Path -Parent $target.File
        [void] [IO.Directory]::CreateDirectory($targetFolder)
        $stage = Join-Path $targetFolder ('.p5r-royal-resume-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllBytes($stage, $candidate)
            $stageHash = Get-SlotHash $stage
            Assert-GameClosed
            if ((Get-SlotHash $source.File) -ne $sourceHash -or (Get-SlotHash $target.File) -ne $targetHash) {
                throw '存档在写入前发生了变化。请重新运行。'
            }
            if ($targetHash) {
                $backupFolder = Join-Path $profileRoot 'p5r-royal-resume-backups'
                [void] [IO.Directory]::CreateDirectory($backupFolder)
                $backup = Join-Path $backupFolder ('{0:yyyyMMdd-HHmmss}-{1}-DATA{2:00}.DAT' -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0, 8)), $targetNumber)
                [IO.File]::Replace($stage, $target.File, $backup)
                Write-Host "备份 $backup"
            } else {
                [IO.File]::Move($stage, $target.File)
            }
            if ((Get-SlotHash $target.File) -ne $stageHash) { throw '写入后校验失败。请使用备份恢复。' }
        } finally {
            if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        }
    } finally {
        $lock.Dispose()
    }
    Write-Host ("已写入 {0} 号槽。进游戏读取该档，从 12 月 24 日晚的涩谷站前广场继续。" -f $targetNumber)
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-RoyalResume }
    catch { throw $_.Exception.GetBaseException().Message }
}
