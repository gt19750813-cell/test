param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [string]$OutputPrefix,

  [string]$Region,

  [double]$Threshold = 58.0,

  [int]$Padding = 12,

  [int]$SampleStepX = 20,

  [int]$SampleStepY = 16
)

$ErrorActionPreference = "Stop"

function Resolve-OutputPrefix {
  param(
    [string]$InputPath,
    [string]$OutputPrefix
  )

  if ($OutputPrefix) {
    return $OutputPrefix
  }

  $dir = Split-Path -Parent $InputPath
  $name = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
  return (Join-Path $dir $name)
}

function Parse-Region {
  param(
    [string]$Region,
    [int]$ImageWidth,
    [int]$ImageHeight
  )

  if ([string]::IsNullOrWhiteSpace($Region)) {
    return @{
      X = 0
      Y = 0
      Width = $ImageWidth
      Height = $ImageHeight
    }
  }

  $parts = $Region.Split(",")
  if ($parts.Length -ne 4) {
    throw "Region must be x,y,width,height"
  }

  $x = [int]$parts[0]
  $y = [int]$parts[1]
  $width = [int]$parts[2]
  $height = [int]$parts[3]

  if ($x -lt 0 -or $y -lt 0 -or $width -le 0 -or $height -le 0) {
    throw "Region values must be positive."
  }

  if (($x + $width) -gt $ImageWidth -or ($y + $height) -gt $ImageHeight) {
    throw "Region exceeds image bounds."
  }

  return @{
    X = $x
    Y = $y
    Width = $width
    Height = $height
  }
}

Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class CutoutEngine {
    static double Dist(Color c1, Color c2) {
        int dr = c1.R - c2.R;
        int dg = c1.G - c2.G;
        int db = c1.B - c2.B;
        return Math.Sqrt(dr * dr + dg * dg + db * db);
    }

    static Color GetColor(byte[] buffer, int stride, int x, int y) {
        int idx = y * stride + x * 3;
        return Color.FromArgb(buffer[idx + 2], buffer[idx + 1], buffer[idx]);
    }

    public static void Run(
        string inputPath,
        string transparentPath,
        string whitePath,
        int rx,
        int ry,
        int rw,
        int rh,
        double threshold,
        int padding,
        int sampleStepX,
        int sampleStepY
    ) {
        using (var src = new Bitmap(inputPath)) {
            var rect = new Rectangle(0, 0, src.Width, src.Height);
            var data = src.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            int stride = data.Stride;
            int bytes = stride * src.Height;
            byte[] buffer = new byte[bytes];
            Marshal.Copy(data.Scan0, buffer, 0, bytes);
            src.UnlockBits(data);

            var bgSamples = new List<Color>();
            for (int x = 0; x < rw; x += Math.Max(1, sampleStepX)) {
                bgSamples.Add(GetColor(buffer, stride, rx + x, ry));
                bgSamples.Add(GetColor(buffer, stride, rx + x, ry + rh - 1));
            }
            for (int y = 0; y < rh; y += Math.Max(1, sampleStepY)) {
                bgSamples.Add(GetColor(buffer, stride, rx, ry + y));
                bgSamples.Add(GetColor(buffer, stride, rx + rw - 1, ry + y));
            }

            bool[,] isBg = new bool[rw, rh];
            bool[,] visited = new bool[rw, rh];
            var q = new Queue<Point>();

            for (int x = 0; x < rw; x++) {
                q.Enqueue(new Point(x, 0));
                q.Enqueue(new Point(x, rh - 1));
            }
            for (int y = 1; y < rh - 1; y++) {
                q.Enqueue(new Point(0, y));
                q.Enqueue(new Point(rw - 1, y));
            }

            while (q.Count > 0) {
                var pt = q.Dequeue();
                int x = pt.X;
                int y = pt.Y;
                if (x < 0 || x >= rw || y < 0 || y >= rh || visited[x, y]) {
                    continue;
                }

                visited[x, y] = true;
                var c = GetColor(buffer, stride, rx + x, ry + y);
                int close = 0;
                foreach (var bg in bgSamples) {
                    if (Dist(c, bg) < threshold) {
                        close++;
                    }
                }

                if (close < 2) {
                    continue;
                }

                isBg[x, y] = true;
                q.Enqueue(new Point(x + 1, y));
                q.Enqueue(new Point(x - 1, y));
                q.Enqueue(new Point(x, y + 1));
                q.Enqueue(new Point(x, y - 1));
            }

            int minX = rw;
            int minY = rh;
            int maxX = 0;
            int maxY = 0;
            bool foundForeground = false;

            for (int y = 0; y < rh; y++) {
                for (int x = 0; x < rw; x++) {
                    if (!isBg[x, y]) {
                        foundForeground = true;
                        if (x < minX) minX = x;
                        if (y < minY) minY = y;
                        if (x > maxX) maxX = x;
                        if (y > maxY) maxY = y;
                    }
                }
            }

            if (!foundForeground) {
                throw new InvalidOperationException("Foreground was not detected. Try a tighter region or a lower threshold.");
            }

            int cropX = Math.Max(0, minX - padding);
            int cropY = Math.Max(0, minY - padding);
            int cropW = Math.Min(rw - cropX, (maxX - minX + 1) + padding * 2);
            int cropH = Math.Min(rh - cropY, (maxY - minY + 1) + padding * 2);

            using (var transparent = new Bitmap(cropW, cropH, PixelFormat.Format32bppArgb))
            using (var white = new Bitmap(cropW, cropH, PixelFormat.Format24bppRgb)) {
                for (int y = 0; y < cropH; y++) {
                    for (int x = 0; x < cropW; x++) {
                        int sx = cropX + x;
                        int sy = cropY + y;
                        var c = GetColor(buffer, stride, rx + sx, ry + sy);
                        if (!isBg[sx, sy]) {
                            transparent.SetPixel(x, y, Color.FromArgb(255, c.R, c.G, c.B));
                            white.SetPixel(x, y, c);
                        } else {
                            transparent.SetPixel(x, y, Color.FromArgb(0, 255, 255, 255));
                            white.SetPixel(x, y, Color.White);
                        }
                    }
                }

                transparent.Save(transparentPath, ImageFormat.Png);
                white.Save(whitePath, ImageFormat.Png);
            }
        }
    }
}
"@

$resolvedInput = (Resolve-Path $InputPath).Path
$outputBase = Resolve-OutputPrefix -InputPath $resolvedInput -OutputPrefix $OutputPrefix

Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Bitmap]::FromFile($resolvedInput)
try {
  $resolvedRegion = Parse-Region -Region $Region -ImageWidth $image.Width -ImageHeight $image.Height
} finally {
  $image.Dispose()
}

$transparentPath = "${outputBase}_cutout.png"
$whitePath = "${outputBase}_white.png"

[CutoutEngine]::Run(
  $resolvedInput,
  $transparentPath,
  $whitePath,
  $resolvedRegion.X,
  $resolvedRegion.Y,
  $resolvedRegion.Width,
  $resolvedRegion.Height,
  $Threshold,
  $Padding,
  $SampleStepX,
  $SampleStepY
)

Write-Output "Saved transparent: $transparentPath"
Write-Output "Saved white: $whitePath"
