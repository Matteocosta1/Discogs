# Icona dell'app: il marchio VINYL / HUSTLER (Wordmark.svg) verde su nero col bagliore. python3 tools/icon.py
import re, numpy as np
from PIL import Image, ImageDraw, ImageFilter
src='/home/claude/discogs/app-ios/VinylHustler/Assets.xcassets/Wordmark.imageset/Wordmark.svg'
svg=open(src).read()
vb=[float(x) for x in re.search(r'viewBox="([^"]+)"',svg).group(1).split()]
W,H=vb[2],vb[3]
S=4096  # render big then downscale
scale=S/W
mask=np.zeros((int(H*scale)+2,S),bool)
for d in re.findall(r' d="([^"]+)"',svg):
    for sub in re.findall(r'M[^MZ]*Z?',d):
        pts=[(float(a)*scale,float(b)*scale) for a,b in re.findall(r'(-?[\d.]+) (-?[\d.]+)',sub)]
        if len(pts)<3: continue
        im=Image.new('1',(mask.shape[1],mask.shape[0]),0)
        ImageDraw.Draw(im).polygon(pts,fill=1)
        mask^=np.array(im)
word=Image.fromarray((mask*255).astype(np.uint8))
# icon 1024, wordmark width ~ 78%
N=1024; target=int(N*0.84)
wh=int(word.height*target/word.width)
word=word.resize((target,wh),Image.LANCZOS)
canvas=Image.new('L',(N,N),0); canvas.paste(word,((N-target)//2,(N-wh)//2))
green=(0x39,0xFF,0x14)
bg=Image.new('RGB',(N,N),(0,0,0))
# soft radial glow behind
yy,xx=np.mgrid[0:N,0:N]; r=np.hypot(xx-N/2,yy-N/2)/(N/2)
rad=np.clip(1-r,0,1)**2*0.18
glowbg=(np.stack([rad*c for c in (0x0A,0xED,0x0C)],-1)).astype(np.uint8)
bg=Image.fromarray(glowbg)
for radius,alpha in ((40,0.55),(14,0.8)):
    g=canvas.filter(ImageFilter.GaussianBlur(radius))
    a=np.array(g,float)/255*alpha
    b=np.array(bg,float)
    b=b*(1-a[...,None])+np.array(green)*a[...,None]
    bg=Image.fromarray(np.clip(b,0,255).astype(np.uint8))
a=np.array(canvas,float)/255
b=np.array(bg,float)*(1-a[...,None])+np.array(green)*a[...,None]
out=Image.fromarray(np.clip(b,0,255).astype(np.uint8))
out.save('AppIcon_new.png')
out.resize((180,180),Image.LANCZOS).save('preview180.png')
print(word.size)
