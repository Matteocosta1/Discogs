from PIL import Image, ImageDraw
import numpy as np
from scipy import ndimage
from skimage import measure

def load(n): return np.array(Image.open(f'g_{n}.png'))>0
H=1024
def crop(m):
    xs=np.where(m.any(0))[0]; return m[:,xs[0]:xs[-1]+1]
G={n:crop(load(n)) for n in ['D','I','S','C','O','Z','E','R']}
E,O,Z=G['E'],G['O'],G['Z']
STEM=125      # larghezza dell'asta (da E e O)
TOP=135       # fondo della barra alta
def rows_full(m,lo,hi):
    r=m.mean(1); idx=[i for i in range(lo,hi) if r[i]>0.8]; return idx[0],idx[-1]
# barra di mezzo della E
mid0,mid1=rows_full(E,400,650)
bot0=rows_full(E,850,1010)[0]
print('E mid',mid0,mid1,'bottom from',bot0, 'O w',O.shape[1],'E w',E.shape[1])

def blank(w): return np.zeros((H,w),bool)
ow=O.shape[1]
R=G['R']
# L: la E senza barra alta e barra di mezzo (asta sottile sopra, spessa sotto, come il carattere)
L=E.copy(); L[:150, 112:]=False; L[mid0-12:mid1+14, 232:]=False
# U: la O senza la barra alta
U=O.copy(); U[:TOP+10, STEM:ow-STEM+10]=False
# H: metà sinistra della R (asta sottile sopra, spessa sotto) + la stessa specchiata + barra di mezzo della R
half=R[:, :240].copy(); half[:150, 108:]=False
mid=R[456:578, 240:440]
Hh=np.hstack([half, blank(200), half[:, ::-1]])
Hh[456:578, 240:440]|=mid
# N: asta sottile a sinistra, asta della H a destra (spessa in basso), diagonale come la Z
N=blank(680); N[:, :108]|=R[:, :108]; N[:, 440:]|=Hh[:, 440:680]
im=Image.fromarray(N.astype(np.uint8)*255); d=ImageDraw.Draw(im)
d.polygon([(0,16),(150,16),(572,840),(572,1007),(430,1007),(0,190)],fill=255); N=np.array(im)>0
# T: barra alta della E + asta della R al centro
tw=600; T=blank(tw)
top=E[:150,:]; top=np.array(Image.fromarray(top).resize((tw,150),Image.NEAREST)); T[:150]|=top
stem=R[:, :228]; cx=(tw-228)//2; T[:, cx:cx+228]|=stem
T[:150, cx:cx+228]|=True
T[:16]=False
# V e Y: geometria con le stesse misure (braccia sottili, base spessa)
def poly(w,pts):
    im=Image.new('L',(w,H)); ImageDraw.Draw(im).polygon(pts,fill=255); return np.array(im)>0
y0,y1=16,1007
vw=ow
V=poly(vw,[(0,y0),(112,y0),(vw/2,y1-210),(vw-112,y0),(vw,y0),(vw/2+120,y1),(vw/2-120,y1)])
yw=ow; ym=520
Y=poly(yw,[(0,y0),(112,y0),(yw/2,ym-150),(yw-112,y0),(yw,y0),(yw/2+114,ym),(yw/2+114,y1),(yw/2-114,y1),(yw/2-114,ym)])
def soften(m): return ndimage.binary_opening(ndimage.binary_closing(m,iterations=3),iterations=8)
V,Y,N,T=soften(V),soften(Y),soften(N),soften(T)
G.update(L=L,U=U,H=Hh,T=T,N=N,V=V,Y=Y)
for k in list(G): G[k]=crop(G[k])
for k,v in G.items(): Image.fromarray((v*255).astype(np.uint8)).save(f'h_{k}.png')

GAP=80; SPACE=300
def word(txt):
    parts=[]
    for ch in txt:
        if ch==' ': parts.append(blank(SPACE)); continue
        parts.append(G[ch]); parts.append(blank(GAP))
    return np.hstack(parts[:-1])
def save_png(m,name,scale=4):
    im=Image.fromarray((m*255).astype(np.uint8)); im.resize((im.width//scale,im.height//scale),Image.LANCZOS).save(name)
def to_svg(m,name,color='#39FF14'):
    pad=20; m=np.pad(m,pad)
    sm=ndimage.gaussian_filter(m.astype(float),1.6)
    cs=measure.find_contours(sm,0.5)
    d=[]
    for c in cs:
        c=measure.approximate_polygon(c,1.2)
        if len(c)<3: continue
        d.append('M'+' L'.join(f'{x-pad:.1f} {y-pad:.1f}' for y,x in c)+'Z')
    h,w=m.shape[0]-2*pad,m.shape[1]-2*pad
    open(name,'w').write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w/8:.0f}" height="{h/8:.0f}"><path fill="{color}" fill-rule="evenodd" d="{" ".join(d)}"/></svg>')
def trim(m):
    ys=np.where(m.any(1))[0]; xs=np.where(m.any(0))[0]; return m[ys[0]:ys[-1]+1, xs[0]:xs[-1]+1]
line=trim(word('VINYL HUSTLER'))
a=trim(word('VINYL')); b=trim(word('HUSTLER'))
LG=110
w=max(a.shape[1],b.shape[1]); st=np.zeros((a.shape[0]+LG+b.shape[0],w),bool)
st[:a.shape[0],(w-a.shape[1])//2:(w-a.shape[1])//2+a.shape[1]]=a
st[a.shape[0]+LG:,(w-b.shape[1])//2:(w-b.shape[1])//2+b.shape[1]]=b
dz=trim(word('DISCOSIZER'))
for m,n in [(line,'line'),(st,'stack'),(dz,'dz')]:
    save_png(m,f'wm_{n}.png'); to_svg(m,f'wm_{n}.svg')
print('ok', line.shape, st.shape)
