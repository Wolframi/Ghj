#requires -Version 5.1
<#
  БИКИНИ-БОТТОМ — ОКЕАН ПОВЕРХ РАБОЧЕГО СТОЛА
  Windows 10/11, Windows PowerShell 5.1. Никаких установок, скачиваний
  и изменений обоев. Прозрачный слой НАД ЗНАЧКАМИ рабочего стола.
  По умолчанию анимация идёт ПОВЕРХ ВСЕХ ОБЫЧНЫХ ОКОН; в меню у часов
  можно отключить этот режим. Клики проходят через море.
  Выключить: значок рыбки возле часов > «Выключить море».
#>
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Нужна Windows 10 или 11.' }

# Windows Forms uses STA. Relaunch in the built-in Windows PowerShell if necessary.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $exe -NoProfile -STA -File $PSCommandPath
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$cs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BikiniDesktopV2 {
    internal static class Layered {
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X=x; Y=y; } }
        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int CX, CY; public SIZE(int w,int h) { CX=w; CY=h; } }
        [StructLayout(LayoutKind.Sequential, Pack=1)] public struct BLENDFUNCTION {
            public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat;
        }
        [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
        [DllImport("gdi32.dll", SetLastError=true)] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);
        [DllImport("user32.dll", SetLastError=true)] private static extern bool UpdateLayeredWindow(
            IntPtr hwnd, IntPtr screenDC, ref POINT pos, ref SIZE size, IntPtr sourceDC,
            ref POINT sourcePos, int colorKey, ref BLENDFUNCTION blend, int flags);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);

        // Per-pixel alpha makes the wallpaper AND the icons visible through the water.
        public static void Present(IntPtr hwnd, Bitmap frame, Rectangle bounds, byte opacity) {
            IntPtr screen = IntPtr.Zero, memory = IntPtr.Zero, hbitmap = IntPtr.Zero, old = IntPtr.Zero;
            try {
                screen = GetDC(IntPtr.Zero);
                if (screen == IntPtr.Zero) throw new InvalidOperationException("GetDC failed");
                memory = CreateCompatibleDC(screen);
                if (memory == IntPtr.Zero) throw new InvalidOperationException("CreateCompatibleDC failed");
                hbitmap = frame.GetHbitmap(Color.FromArgb(0, 0, 0, 0));
                if (hbitmap == IntPtr.Zero) throw new InvalidOperationException("GetHbitmap failed");
                old = SelectObject(memory, hbitmap);
                POINT pos = new POINT(bounds.Left, bounds.Top);
                POINT src = new POINT(0, 0);
                SIZE size = new SIZE(bounds.Width, bounds.Height);
                BLENDFUNCTION blend = new BLENDFUNCTION();
                blend.BlendOp = 0; // AC_SRC_OVER
                blend.SourceConstantAlpha = opacity;
                blend.AlphaFormat = 1; // AC_SRC_ALPHA
                if (!UpdateLayeredWindow(hwnd, screen, ref pos, ref size, memory,
                                          ref src, 0, ref blend, 2))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            } finally {
                if (memory != IntPtr.Zero && old != IntPtr.Zero) SelectObject(memory, old);
                if (hbitmap != IntPtr.Zero) DeleteObject(hbitmap);
                if (memory != IntPtr.Zero) DeleteDC(memory);
                if (screen != IntPtr.Zero) ReleaseDC(IntPtr.Zero, screen);
            }
        }
    }

    internal sealed class Bubble {
        public float X, Y, R, Speed, Phase;
    }
    internal sealed class Fish {
        public float X, Y, Size, Speed, Dir, Phase;
        public Color Body;
        public int Pattern;
    }
    internal sealed class Jelly {
        public float X, Y, Size, Phase, Speed;
        public Color Body;
    }
    internal sealed class Mote {
        public float X, Y, Phase, Size;
    }

    internal sealed class OceanOverlay : Form {
        private readonly Random random = new Random(12881);
        private readonly List<Bubble> bubbles = new List<Bubble>();
        private readonly List<Fish> fishes = new List<Fish>();
        private readonly List<Jelly> jellies = new List<Jelly>();
        private readonly List<Mote> motes = new List<Mote>();
        private readonly Timer timer = new Timer();
        private readonly Stopwatch watch = Stopwatch.StartNew();
        private readonly Rectangle area;
        private Bitmap back;
        private Bitmap world;
        private Bitmap frame;
        private double last = 0;
        private float t = 0f;
        private byte opacity = 235;
        private bool paused;
        private bool busy;
        private float s;
        public bool IsPaused { get { return paused; } }
        public bool IsStrong { get { return opacity >= 220; } }

        internal OceanOverlay() {
            area = SystemInformation.VirtualScreen;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            Bounds = area;
            TopMost = true; // visible over regular windows from the moment the ocean starts
            s = Math.Max(0.65f, Math.Min(1.70f, Math.Min(area.Width / 1600f, area.Height / 900f)));
            back = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppPArgb);
            world = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppPArgb);
            frame = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppPArgb);
            using (Graphics g = Graphics.FromImage(back)) PaintBackground(g);
            using (Graphics g = Graphics.FromImage(world)) PaintWorld(g);

            for (int i=0; i<64; i++) bubbles.Add(NewBubble(true));
            Color[] palette = { Color.FromArgb(255,211,73), Color.FromArgb(255,116,118),
                Color.FromArgb(113,239,222), Color.FromArgb(245,126,221),
                Color.FromArgb(134,185,255), Color.FromArgb(255,175,103) };
            for (int i=0; i<16; i++) {
                fishes.Add(new Fish {
                    X=(float)random.NextDouble()*area.Width,
                    Y=(float)(area.Height*(.14 + random.NextDouble()*.62)),
                    Size=(20 + (float)random.NextDouble()*25)*s,
                    Speed=(26+(float)random.NextDouble()*58)*s,
                    Dir=(i%2==0?1f:-1f), Phase=(float)random.NextDouble()*6.28f,
                    Body=palette[i%palette.Length], Pattern=i%3
                });
            }
            for (int i=0;i<4;i++) jellies.Add(new Jelly {
                X=(float)(area.Width*(.13+i*.25)), Y=(float)(area.Height*(.27+i*.09)),
                Size=(25+i*8)*s, Phase=i*1.6f, Speed=(11+i*4)*s,
                Body=i%2==0 ? Color.FromArgb(255,151,219) : Color.FromArgb(159,190,255)
            });
            for (int i=0;i<95;i++) motes.Add(new Mote {
                X=(float)random.NextDouble()*area.Width,
                Y=(float)random.NextDouble()*area.Height,
                Phase=(float)random.NextDouble()*6.28f,
                Size=(1.0f + (float)random.NextDouble()*2.4f)*s
            });
            long pixels=(long)area.Width*area.Height;
            timer.Interval=pixels>6500000?75:(pixels>3200000?48:33);
            timer.Tick+=delegate(object sender,EventArgs args) { Tick(); };
            Shown+=delegate(object sender,EventArgs args) { timer.Start(); Tick(); };
            FormClosed+=delegate(object sender,FormClosedEventArgs args) {
                timer.Stop(); timer.Dispose();
                back.Dispose(); world.Dispose(); frame.Dispose();
            };
        }
        public void SetStronger(bool strong) { opacity = (byte)(strong ? 235 : 154); if (paused) Render(); }
        public void TogglePause() { paused = !paused; if (paused) timer.Stop(); else { last=watch.Elapsed.TotalSeconds; timer.Start(); } }

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams p=base.CreateParams;
                p.ExStyle |= 0x00080000 | 0x00000020 | 0x00000080 | 0x08000000;
                // WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
                return p;
            }
        }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0084) { m.Result = new IntPtr(-1); return; } // HTTRANSPARENT
            if (m.Msg == 0x0021) { m.Result = new IntPtr(3); return; }  // MA_NOACTIVATE
            base.WndProc(ref m);
        }
        protected override void OnPaintBackground(PaintEventArgs e) { /* Layered pixels */ }
        protected override void OnPaint(PaintEventArgs e) { /* Updated by UpdateLayeredWindow */ }

        private Bubble NewBubble(bool anywhere) {
            return new Bubble {
                X=(float)random.NextDouble()*area.Width,
                Y=anywhere?(float)random.NextDouble()*area.Height:area.Height+30*s,
                R=(3f+(float)Math.Pow(random.NextDouble(),1.3)*12f)*s,
                Speed=(25+(float)random.NextDouble()*70)*s,
                Phase=(float)random.NextDouble()*6.283f
            };
        }
        private void Tick() {
            if (busy || IsDisposed || !IsHandleCreated || paused) return;
            busy=true;
            try {
                double now=watch.Elapsed.TotalSeconds;
                float dt=(float)Math.Max(0.005,Math.Min(.09,now-last));
                last=now;
                t+=dt;
                foreach (Bubble b in bubbles) {
                    b.Y -= b.Speed*dt;
                    b.X += (float)Math.Sin(t*1.9+b.Phase)*4f*s*dt;
                    if(b.Y < -b.R*3) {
                        Bubble n=NewBubble(false);
                        b.X=n.X;b.Y=n.Y;b.R=n.R;b.Speed=n.Speed;b.Phase=n.Phase;
                    }
                }
                foreach(Fish f in fishes) {
                    f.X += f.Speed*f.Dir*dt;
                    if(f.X > area.Width+100*s) f.X=-100*s;
                    if(f.X < -100*s) f.X=area.Width+100*s;
                }
                foreach(Jelly j in jellies) {
                    j.Y+=(float)Math.Sin(t*.65f+j.Phase)*3.5f*dt*s;
                    j.X+=j.Speed*dt;
                    if(j.X>area.Width+70*s) j.X=-70*s;
                }
                Render();
            } catch (Exception exc) {
                timer.Stop();
                MessageBox.Show("Ошибка анимации: " + exc.Message + "\nПерезапустите скрипт.","Океан",MessageBoxButtons.OK,MessageBoxIcon.Warning);
                Close();
            } finally { busy=false; }
        }
        private static void Setup(Graphics g) {
            g.SmoothingMode=SmoothingMode.AntiAlias;
            g.InterpolationMode=InterpolationMode.HighQualityBilinear;
            g.PixelOffsetMode=PixelOffsetMode.HighQuality;
            g.CompositingQuality=CompositingQuality.HighSpeed;
        }
        private void Render() {
            using(Graphics g=Graphics.FromImage(frame)) {
                g.Clear(Color.Transparent);
                Setup(g);
                g.DrawImageUnscaled(back,0,0);
                DrawRays(g);
                DrawCaustics(g);
                g.DrawImageUnscaled(world,0,0);
                DrawSeaweed(g);
                DrawMotes(g);
                foreach(Jelly j in jellies) DrawJelly(g,j);
                foreach(Fish f in fishes) DrawFish(g,f);
                foreach(Bubble b in bubbles) DrawBubble(g,b);
                DrawSurface(g);
                DrawJoke(g);
            }
            Layered.Present(Handle,frame,area,opacity);
        }
        private static SolidBrush B(int a,int r,int g,int b) { return new SolidBrush(Color.FromArgb(a,r,g,b)); }
        private static Pen P(int a,int r,int g,int b,float width) { return new Pen(Color.FromArgb(a,r,g,b),width); }

        private void PaintBackground(Graphics g) {
            Setup(g);
            float w=area.Width,h=area.Height;
            using(LinearGradientBrush sea=new LinearGradientBrush(new PointF(0,0),new PointF(0,h),
                      Color.FromArgb(72,18,188,213),Color.FromArgb(135,2,53,125)))
                g.FillRectangle(sea,0,0,w,h);
            using(SolidBrush glimmer=B(18,208,250,248)) {
                for(int i=0;i<70;i++) {
                    float x=(float)random.NextDouble()*w, y=(float)random.NextDouble()*h*.85f;
                    float d=(float)random.NextDouble()*3*s+1;
                    g.FillEllipse(glimmer,x,y,d,d);
                }
            }
            using(SolidBrush far=B(54,0,108,147)) {
                PointF[] deep = {new PointF(0,h*.73f),new PointF(w*.15f,h*.70f),new PointF(w*.36f,h*.77f),
                  new PointF(w*.55f,h*.68f),new PointF(w*.80f,h*.75f),new PointF(w,h*.68f),new PointF(w,h),new PointF(0,h)};
                g.FillPolygon(far,deep);
            }
            // Five-petalled flower clouds inspired by an old-school underwater cartoon.
            Flower(g,w*.13f,h*.18f,63*s,Color.FromArgb(70,93,210,225));
            Flower(g,w*.64f,h*.14f,50*s,Color.FromArgb(75,152,228,161));
            Flower(g,w*.85f,h*.31f,40*s,Color.FromArgb(64,227,166,223));
            Flower(g,w*.36f,h*.35f,28*s,Color.FromArgb(51,250,222,166));
        }
        private void Flower(Graphics g,float x,float y,float radius,Color color) {
            using(Pen p=new Pen(color,6*s)) {
                for(int i=0;i<5;i++) {
                    double a=i*Math.PI*2/5;
                    float ex=x+(float)Math.Cos(a)*radius*.65f;
                    float ey=y+(float)Math.Sin(a)*radius*.65f;
                    g.DrawEllipse(p,ex-radius*.35f,ey-radius*.35f,radius*.7f,radius*.7f);
                }
            }
        }
        private void PaintWorld(Graphics g) {
            Setup(g);
            float w=area.Width,h=area.Height;
            float floor=h*.86f;
            using(SolidBrush distantSand=B(140,232,203,130)) {
                PointF[] hill={new PointF(0,floor+22*s),new PointF(w*.12f,floor-14*s),
                 new PointF(w*.31f,floor+18*s),new PointF(w*.54f,floor-20*s),
                 new PointF(w*.75f,floor+11*s),new PointF(w,floor-13*s),new PointF(w,h),new PointF(0,h)};
                g.FillPolygon(distantSand,hill);
            }
            using(SolidBrush sandy=B(195,239,208,134)) {
                PointF[] dune={new PointF(0,floor+49*s),new PointF(w*.16f,floor+20*s),
                 new PointF(w*.38f,floor+42*s),new PointF(w*.55f,floor+6*s),
                 new PointF(w*.80f,floor+38*s),new PointF(w,floor+12*s),new PointF(w,h),new PointF(0,h)};
                g.FillPolygon(sandy,dune);
            }
            using(SolidBrush grains=B(115,113,102,70)) {
                for(int i=0;i<145;i++) {
                    float x=(float)random.NextDouble()*w;
                    float y=(float)(h*(.91+random.NextDouble()*.085));
                    float r=(float)random.NextDouble()*2*s+.5f;
                    g.FillEllipse(grains,x,y,r*2,r);
                }
            }
            DrawRockHouse(g,w*.18f,h*.91f);
            DrawPineapple(g,w*.49f,h*.92f);
            DrawStoneHouse(g,w*.79f,h*.90f);
            for(int i=0;i<21;i++) {
                float x=(i+.2f)*w/21f;
                float y=h*(.91f+(i%3)*.018f);
                Coral(g,x,y,(15+(i%4)*8)*s,i%4);
            }
            Starfish(g,w*.33f,h*.947f,17*s);
            Starfish(g,w*.67f,h*.956f,13*s);
        }
        private void DrawPineapple(Graphics g,float x,float y) {
            GraphicsState state=g.Save();
            g.TranslateTransform(x,y);
            g.ScaleTransform(s,s);
            using(SolidBrush shadow=B(62,46,79,75)) g.FillEllipse(shadow,-89,-9,178,24);
            // Spiky leafy crown.
            using(SolidBrush leaves=B(235,23,158,74)) {
                for(int i=0;i<7;i++) {
                    float spread=(i-3)*20f;
                    g.FillPolygon(leaves,new PointF[]{new PointF(0,-192),new PointF(spread,-274+Math.Abs(i-3)*10),
                       new PointF(spread*.55f+12,-199)});
                }
            }
            using(Pen lines=P(225,13,95,49,3)) {
                for(int i=-2;i<=2;i++) {
                    g.DrawLine(lines,-5,-197, (i*20), -242+Math.Abs(i)*10);
                }
            }
            Rectangle body=new Rectangle(-77,-203,154,205);
            using(LinearGradientBrush orange=new LinearGradientBrush(body,
                   Color.FromArgb(245,255,196,57),Color.FromArgb(246,213,105,25),LinearGradientMode.Horizontal))
                g.FillEllipse(orange,body);
            using(Pen outline=P(255,116,87,33,4)) g.DrawEllipse(outline,body);
            using(GraphicsPath clip=new GraphicsPath()) {
                clip.AddEllipse(body);
                GraphicsState clipped=g.Save();
                g.SetClip(clip);
                using(Pen hatch=P(135,143,87,29,3)) {
                    for(int i=-240;i<300;i+=24) {
                        g.DrawLine(hatch,i,-225,i+235,50);
                        g.DrawLine(hatch,i,50,i+235,-225);
                    }
                }
                g.Restore(clipped);
            }
            // Portholes, bolts and blue glass.
            DrawPorthole(g,-34,-136,21);
            DrawPorthole(g,34,-98,22);
            using(SolidBrush entry=B(255,56,77,101)) g.FillPie(entry,-30,-69,60,85,180,180);
            using(Pen entryFrame=P(255,125,111,71,7)) g.DrawArc(entryFrame,-30,-69,60,85,180,180);
            using(SolidBrush knob=B(255,255,227,110)) g.FillEllipse(knob,11,-28,9,9);
            using(Pen steps=P(190,155,98,44,5)) g.DrawLine(steps,-38,4,39,4);
            g.Restore(state);
        }
        private void DrawPorthole(Graphics g,float x,float y,float r) {
            using(SolidBrush frame=B(255,195,144,55)) g.FillEllipse(frame,x-r-4,y-r-4,2*r+8,2*r+8);
            RectangleF glass=new RectangleF(x-r,y-r,2*r,2*r);
            using(LinearGradientBrush blue=new LinearGradientBrush(glass,Color.FromArgb(245,181,248,249),
                   Color.FromArgb(245,24,117,175),LinearGradientMode.ForwardDiagonal))
                g.FillEllipse(blue,glass);
            using(Pen edge=P(245,105,74,32,3)) g.DrawEllipse(edge,x-r-4,y-r-4,2*r+8,2*r+8);
            using(Pen shine=P(180,247,255,255,3)) g.DrawArc(shine,x-r+5,y-r+5,2*r-12,2*r-12,200,74);
            using(SolidBrush bolt=B(230,239,221,142)) {
                for(int i=0;i<6;i++) {
                    double a=i*Math.PI/3;
                    g.FillEllipse(bolt,x+(float)Math.Cos(a)*(r+2)-2,y+(float)Math.Sin(a)*(r+2)-2,4,4);
                }
            }
        }
        private void DrawRockHouse(Graphics g,float x,float y) {
            GraphicsState state=g.Save(); g.TranslateTransform(x,y);g.ScaleTransform(s,s);
            using(SolidBrush shadow=B(65,38,68,80)) g.FillEllipse(shadow,-112,-10,220,25);
            using(LinearGradientBrush rock=new LinearGradientBrush(new Rectangle(-106,-124,212,129),
                 Color.FromArgb(245,201,167,223),Color.FromArgb(245,106,89,144),LinearGradientMode.Vertical))
                g.FillEllipse(rock,-106,-124,212,129);
            using(Pen rim=P(225,86,72,124,4)) g.DrawArc(rim,-106,-124,212,129,185,170);
            using(SolidBrush entry=B(244,57,53,91)) g.FillPie(entry,-30,-82,60,85,180,180);
            using(Pen border=P(215,79,66,114,5)) g.DrawArc(border,-30,-82,60,85,180,180);
            using(Pen shine=P(135,245,231,253,8)) g.DrawArc(shine,-90,-112,175,103,207,72);
            g.Restore(state);
        }
        private void DrawStoneHouse(Graphics g,float x,float y) {
            GraphicsState state=g.Save();g.TranslateTransform(x,y);g.ScaleTransform(s,s);
            using(SolidBrush shadow=B(64,44,63,71)) g.FillEllipse(shadow,-73,-8,153,23);
            PointF[] shape={new PointF(-49,0),new PointF(-63,-139),new PointF(-32,-160),
                new PointF(30,-160),new PointF(58,-132),new PointF(48,0)};
            using(LinearGradientBrush stone=new LinearGradientBrush(new Rectangle(-70,-165,140,170),
              Color.FromArgb(242,165,178,170),Color.FromArgb(240,80,111,130),LinearGradientMode.Horizontal))
                g.FillPolygon(stone,shape);
            using(Pen dark=P(220,52,88,106,4)) g.DrawPolygon(dark,shape);
            using(SolidBrush brow=B(240,62,89,105)) {
                g.FillRectangle(brow,-46,-126,34,13);g.FillRectangle(brow,14,-126,34,13);
            }
            using(SolidBrush eyes=B(235,18,63,91)) {
                g.FillEllipse(eyes,-39,-110,22,27);g.FillEllipse(eyes,18,-110,22,27);
            }
            using(SolidBrush nose=B(250,121,144,151))
                g.FillPolygon(nose,new PointF[]{new PointF(-3,-108),new PointF(-19,-64),new PointF(13,-64)});
            using(SolidBrush door=B(245,34,62,83)) g.FillRectangle(door,-20,-45,41,46);
            using(Pen lip=P(210,39,73,88,6)) g.DrawLine(lip,-31,-52,32,-52);
            g.Restore(state);
        }
        private void Coral(Graphics g,float x,float y,float size,int variety) {
            GraphicsState state=g.Save();g.TranslateTransform(x,y);
            Color[] colors={Color.FromArgb(232,253,125,151),Color.FromArgb(229,250,152,102),
              Color.FromArgb(230,180,112,214),Color.FromArgb(220,74,211,167)};
            using(Pen stem=new Pen(colors[variety],Math.Max(3,size*.21f))) {
                stem.StartCap=LineCap.Round;stem.EndCap=LineCap.Round;
                g.DrawLine(stem,0,0,-size*.08f,-size);
                g.DrawLine(stem,-size*.05f,-size*.50f,-size*.47f,-size*.83f);
                g.DrawLine(stem,-size*.06f,-size*.31f,size*.48f,-size*.69f);
                g.DrawLine(stem,size*.24f,-size*.52f,size*.31f,-size*.99f);
            }
            g.Restore(state);
        }
        private void Starfish(Graphics g,float x,float y,float r) {
            PointF[] pts=new PointF[10];
            for(int i=0;i<10;i++) {
                double a=-Math.PI/2+i*Math.PI/5;
                float rr=i%2==0?r:r*.44f;
                pts[i]=new PointF(x+(float)Math.Cos(a)*rr,y+(float)Math.Sin(a)*rr);
            }
            using(SolidBrush orange=B(230,251,139,118)) g.FillPolygon(orange,pts);
            using(Pen edge=P(200,172,81,87,2*s)) g.DrawPolygon(edge,pts);
        }
        private void DrawRays(Graphics g) {
            float w=area.Width,h=area.Height;
            using(LinearGradientBrush ray=new LinearGradientBrush(new PointF(0,0),new PointF(0,h),
                Color.FromArgb(57,240,255,211),Color.FromArgb(0,240,255,211))) {
                for(int i=0;i<8;i++) {
                    float shift=(float)Math.Sin(t*.22f+i*.75f)*32*s;
                    float origin=w*.10f+i*w*.085f+shift;
                    g.FillPolygon(ray,new PointF[]{new PointF(origin-20*s,0),new PointF(origin+24*s,0),
                      new PointF(origin+((i-4)*.14f+0.2f)*h,h),
                      new PointF(origin+((i-4)*.12f-0.07f)*h,h)});
                }
            }
        }
        private void DrawCaustics(Graphics g) {
            float w=area.Width,h=area.Height;
            // Moving projected sunshine on the sandy bottom.
            using(Pen p=P(60,229,252,224,2.5f*s)) {
                for(int j=0;j<16;j++) {
                    List<PointF> points=new List<PointF>();
                    float by=h*(.83f+j*.012f);
                    for(float x=0;x<=w+20;x+=20*s) {
                        float wave=(float)(Math.Sin(x/(48*s)+j*.52+t*1.4)*4*s+
                                         Math.Sin(x/(92*s)-t*.84+j)*5*s);
                        points.Add(new PointF(x,by+wave));
                    }
                    if(points.Count>1) g.DrawLines(p,points.ToArray());
                }
            }
        }
        private void DrawSeaweed(Graphics g) {
            float w=area.Width,h=area.Height;
            for(int i=0;i<28;i++) {
                float x=(i+.45f)*w/28f;
                float y=h*(.91f+(i%3)*.017f);
                float length=(43+i%6*14)*s;
                float wave=(float)Math.Sin(t*.8f+i*.57f)*15*s;
                Color col=i%2==0?Color.FromArgb(210,37,161,108):Color.FromArgb(192,22,123,101);
                using(Pen stem=new Pen(col,Math.Max(3f,5*s))) {
                    stem.StartCap=LineCap.Round;stem.EndCap=LineCap.Round;
                    g.DrawBezier(stem,new PointF(x,y),new PointF(x-15*s,y-length*.24f),
                       new PointF(x+15*s+wave,y-length*.77f),new PointF(x+wave,y-length));
                }
                // Animated fronds.
                using(Pen leaf=P(192,70,196,118,3.4f*s)) {
                    g.DrawBezier(leaf,new PointF(x,y-length*.47f),new PointF(x-25*s,y-length*.52f),
                     new PointF(x-30*s+wave*.4f,y-length*.68f),new PointF(x-23*s+wave*.4f,y-length*.79f));
                    g.DrawBezier(leaf,new PointF(x+wave*.6f,y-length*.72f),new PointF(x+20*s,y-length*.69f),
                     new PointF(x+28*s+wave,y-length*.88f),new PointF(x+25*s+wave,y-length*.98f));
                }
            }
        }
        private void DrawMotes(Graphics g) {
            using(SolidBrush snow=B(90,235,255,245)) {
                foreach(Mote m in motes) {
                    float x=m.X+(float)Math.Sin(t*.4f+m.Phase)*11*s;
                    float y=m.Y+(float)Math.Sin(t*.9f+m.Phase)*8*s;
                    g.FillEllipse(snow,x,y,m.Size,m.Size);
                }
            }
        }
        private void DrawFish(Graphics g,Fish f) {
            GraphicsState state=g.Save();
            g.TranslateTransform(f.X,f.Y+(float)Math.Sin(t*1.9f+f.Phase)*8*s);
            g.ScaleTransform(f.Dir,1);
            float a=f.Size;
            float wag=(float)Math.Sin(t*9.5f+f.Phase)*a*.19f;
            Color dark=ControlPaint.Dark(f.Body), bright=ControlPaint.Light(f.Body);
            using(SolidBrush tail=new SolidBrush(Color.FromArgb(234,dark)))
                g.FillPolygon(tail,new PointF[]{new PointF(-a*.45f,0),new PointF(-a*1.15f,-a*.58f+wag),
                                             new PointF(-a*1.13f,a*.58f+wag)});
            using(SolidBrush fin=new SolidBrush(Color.FromArgb(239,bright))) {
                g.FillPolygon(fin,new PointF[]{new PointF(-a*.27f,-a*.21f),new PointF(a*.02f,-a*.80f),
                     new PointF(a*.32f,-a*.16f)});
                g.FillPolygon(fin,new PointF[]{new PointF(-a*.20f,a*.18f),new PointF(a*.13f,a*.60f),
                     new PointF(a*.37f,a*.18f)});
            }
            RectangleF body=new RectangleF(-a*.61f,-a*.39f,a*1.35f,a*.78f);
            using(LinearGradientBrush shade=new LinearGradientBrush(body,bright,dark,LinearGradientMode.Vertical))
                g.FillEllipse(shade,body);
            using(Pen edge=P(205,33,74,98,2*s)) g.DrawEllipse(edge,body);
            if(f.Pattern==1) {
                using(Pen stripes=P(95,255,255,255,4*s)) {
                    g.DrawArc(stripes,-a*.17f,-a*.37f,a*.4f,a*.74f,100,151);
                    g.DrawArc(stripes,-a*.38f,-a*.34f,a*.36f,a*.68f,100,155);
                }
            }
            if(f.Pattern==2) {
                using(SolidBrush dots=B(139,252,247,204)) {
                    g.FillEllipse(dots,-a*.19f,-a*.20f,a*.13f,a*.11f);
                    g.FillEllipse(dots,-a*.37f,a*.06f,a*.10f,a*.10f);
                }
            }
            using(SolidBrush eye= new SolidBrush(Color.FromArgb(248,255,255,245)))
                g.FillEllipse(eye,a*.34f,-a*.25f,a*.29f,a*.29f);
            using(SolidBrush pupil=B(255,30,45,67))
                g.FillEllipse(pupil,a*.49f,-a*.16f,a*.12f,a*.15f);
            using(SolidBrush sparkle=B(255,255,255,255))
                g.FillEllipse(sparkle,a*.515f,-a*.14f,a*.04f,a*.05f);
            using(Pen grin=P(233,55,64,68,1.5f*s))
                g.DrawArc(grin,a*.39f,a*.07f,a*.29f,a*.16f,13,149);
            g.Restore(state);
        }
        private void DrawJelly(Graphics g,Jelly j) {
            GraphicsState state=g.Save();
            float bob=(float)Math.Sin(t*1.3f+j.Phase)*12*s;
            g.TranslateTransform(j.X,j.Y+bob);
            float p=1f+(float)Math.Sin(t*2.8f+j.Phase)*.08f;
            float a=j.Size*p;
            using(Pen tendril=P(190,222,214,255,2.2f*s)) {
                for(int i=-2;i<=2;i++) {
                    float x=i*a*.33f;
                    g.DrawBezier(tendril,x,0,x-7*s,a*.32f,
                     x+(float)Math.Sin(t*2f+j.Phase+i)*10*s,a*.85f,
                     x+(float)Math.Sin(t*2f+j.Phase+i)*8*s,a*1.36f);
                }
            }
            using(SolidBrush rim=new SolidBrush(Color.FromArgb(220,j.Body)))
                g.FillPie(rim,-a,-a*.82f,a*2,a*1.56f,180,180);
            using(LinearGradientBrush dome=new LinearGradientBrush(new RectangleF(-a,-a*.84f,a*2,a*.88f),
                Color.FromArgb(205,250,241,255),Color.FromArgb(160,j.Body),LinearGradientMode.Vertical))
                g.FillPie(dome,-a,-a*.82f,a*2,a*1.56f,180,180);
            using(Pen edge=P(213,255,225,252,2.5f*s))
                g.DrawArc(edge,-a,-a*.82f,a*2,a*1.56f,180,180);
            g.Restore(state);
        }
        private void DrawBubble(Graphics g,Bubble b) {
            float x=b.X+(float)Math.Sin(t*1.4f+b.Phase)*6*s;
            float y=b.Y;
            float r=b.R;
            using(SolidBrush surface=B(31,208,247,255)) g.FillEllipse(surface,x-r,y-r,r*2,r*2);
            using(Pen rim=P(171,204,249,255,Math.Max(1.2f,1.65f*s)))
                g.DrawEllipse(rim,x-r,y-r,r*2,r*2);
            using(Pen glow=P(210,253,255,255,Math.Max(1.1f,1.6f*s)))
                g.DrawArc(glow,x-r*.71f,y-r*.69f,r*1.43f,r*1.45f,189,67);
            using(SolidBrush spec=B(220,255,255,255))
                g.FillEllipse(spec,x-r*.44f,y-r*.51f,Math.Max(1.4f,r*.28f),Math.Max(1.4f,r*.26f));
        }
        private void DrawSurface(Graphics g) {
            float w=area.Width;
            List<PointF> points=new List<PointF>();
            for(float x=0;x<=w+15*s;x+=15*s)
                points.Add(new PointF(x,10*s+(float)(Math.Sin(x/(65*s)+t*1.75f)*4*s+
                     Math.Sin(x/(28*s)-t*.83f)*2*s)));
            if(points.Count>1) {
                using(Pen p=P(133,230,255,251,2.4f*s)) g.DrawLines(p,points.ToArray());
                using(Pen p=P(53,255,255,255,5.5f*s)) g.DrawLines(p,points.ToArray());
            }
        }
        private void DrawJoke(Graphics g) {
            // Quiet speech bubble for a few seconds, not constantly blocking the desktop.
            int cycle=(int)(t/18f);
            float within=t%18f;
            if(within>4.8f || within<.6f) return;
            string[] phrases={"404: СУША НЕ НАЙДЕНА", "ПЛАНКТОН УКРАЛ WI-FI!",
                "ОПЯТЬ ПОНЕДЕЛЬНИК В БИКИНИ-БОТТОМЕ", "БУЛЬ-БУЛЬ, НАЧАЛЬНИК!"};
            float alpha=Math.Min(1f,Math.Min((within-.6f)*1.5f,(4.8f-within)*1.3f));
            float sz=Math.Max(14f,Math.Min(22f,18*s));
            using(Font font=new Font("Segoe UI",sz,FontStyle.Bold,GraphicsUnit.Pixel)) {
                SizeF measured=g.MeasureString(phrases[cycle%phrases.Length],font);
                float x=(area.Width-measured.Width)*.5f, y=area.Height*.09f;
                using(SolidBrush bg=B((int)(105*alpha),10,57,85))
                    g.FillEllipse(bg,x-19*s,y-10*s,measured.Width+38*s,measured.Height+20*s);
                using(SolidBrush text=B((int)(243*alpha),255,252,217))
                    g.DrawString(phrases[cycle%phrases.Length],font,text,x,y);
            }
        }
    }

    public static class Start {
        private static Icon FishTrayIcon() {
            using(Bitmap bmp=new Bitmap(32,32)) {
                using(Graphics g=Graphics.FromImage(bmp)) {
                    g.Clear(Color.Transparent); g.SmoothingMode=SmoothingMode.AntiAlias;
                    g.FillPolygon(Brushes.DarkOrange,new PointF[]{new PointF(12,16),new PointF(1,7),new PointF(1,26)});
                    g.FillEllipse(Brushes.Gold,8,8,23,17);
                    g.FillEllipse(Brushes.White,23,11,5,5);
                    g.FillEllipse(Brushes.Black,25,13,2,2);
                    g.DrawArc(Pens.SaddleBrown,20,15,7,5,6,150);
                }
                IntPtr handle=bmp.GetHicon();
                try {return (Icon)Icon.FromHandle(handle).Clone();}
                finally {Layered.DestroyIcon(handle);}
            }
        }
        public static void Run() {
            bool first;
            using(System.Threading.Mutex mutex = new System.Threading.Mutex(true,
              @"Local\FunnySeaDesktop_Aquarium_v1",out first)) {
                if(!first) {
                    MessageBox.Show("Море уже запущено! Сначала выключи старую рыбку возле часов.",
                                   "Буль-буль!",MessageBoxButtons.OK,MessageBoxIcon.Information);
                    return;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using(OceanOverlay ocean=new OceanOverlay())
                using(Icon icon=FishTrayIcon())
                using(NotifyIcon tray=new NotifyIcon())
                using(ContextMenuStrip menu=new ContextMenuStrip()) {
                    ToolStripMenuItem allWindows=new ToolStripMenuItem("Поверх всех окон");
                    allWindows.CheckOnClick=true;
                    allWindows.Checked=true;
                    allWindows.CheckedChanged+=delegate(object sender,EventArgs e){ocean.TopMost=allWindows.Checked;};
                    menu.Items.Add(allWindows);
                    ToolStripMenuItem gentle=new ToolStripMenuItem("Нежный эффект (прозрачнее)");
                    gentle.CheckOnClick=true;
                    gentle.CheckedChanged+=delegate(object sender,EventArgs e){ocean.SetStronger(!gentle.Checked);};
                    menu.Items.Add(gentle);
                    ToolStripMenuItem pause=new ToolStripMenuItem("Пауза");
                    pause.CheckOnClick=true;
                    pause.CheckedChanged+=delegate(object sender,EventArgs e){ocean.TogglePause();};
                    menu.Items.Add(pause);
                    menu.Items.Add(new ToolStripSeparator());
                    menu.Items.Add("Выключить море",null,delegate(object sender,EventArgs e){Application.Exit();});
                    tray.Icon=icon; tray.Text="Бикини-Боттом на рабочем столе";
                    tray.ContextMenuStrip=menu;
                    tray.DoubleClick+=delegate(object sender,EventArgs e){Application.Exit();};
                    tray.Visible=true;
                    try {Application.Run(ocean);}
                    finally {tray.Visible=false;}
                }
            }
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies @('System', 'System.Windows.Forms', 'System.Drawing') -Language CSharp
    [BikiniDesktopV2.Start]::Run()
} catch {
    Write-Host ('Не удалось запустить море: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Нажмите Enter для выхода...'
    [void][Console]::ReadLine()
}
