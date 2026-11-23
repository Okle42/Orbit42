// 夜視 Claude 娃娃（只有娃娃、透明底）—— 取代 Claude Code 開頭畫在終端機左上角的那隻字元娃娃
// 用法：mountClawdNV(canvasElement, { color: '#4fc36a' })
// 回傳 { setColor(hex), stop() }
(function(){
const GLYPHS = "01ABCDEFGHKMNRSTXZ<>/\\#%&@$";
const RAMP = " .:-=+*oO#%@";

function buildModel(){
  let a = 42; const rnd=()=>{a|=0;a=a+0x6D2B79F5|0;let t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296};
  const col=c=>c-8.5, row=r=>5-r;
  const parts=[{name:'body',box:[col(2),col(15),row(8),row(0),-3,3]},
    {name:'armL',box:[col(0),col(2),row(6),row(4),-1,1],pivot:[col(2),row(5)]},
    {name:'armR',box:[col(15),col(17),row(6),row(4),-1,1],pivot:[col(15),row(5)]}];
  [2,4,12,14].forEach((c,i)=>parts.push({name:'leg',box:[col(c),col(c+1),row(10),row(8),-1.2,1.2],phase:i%2}));
  const EYES=[[col(4),col(5)],[col(12),col(13)]], S=0.2, pts=[];
  parts.forEach((P,pi)=>{
    const [x0,x1,y0,y1,z0,z1]=P.box;
    const face=(ax,val,n,a0,a1,b0,b1)=>{for(let u=a0+S/2;u<a1;u+=S)for(let v=b0+S/2;v<b1;v+=S){
      const p=ax===0?[val,u,v]:ax===1?[u,val,v]:[u,v,val];
      let eye=false; if(pi===0&&ax===2&&n[2]>0) for(const [e0,e1] of EYES) if(p[0]>e0&&p[0]<e1&&p[1]>row(4)&&p[1]<row(2)) eye=true;
      pts.push({p,n,pi,eye,g:(rnd()*GLYPHS.length)|0});}};
    face(2,z1,[0,0,1],x0,x1,y0,y1);face(2,z0,[0,0,-1],x0,x1,y0,y1);
    face(0,x1,[1,0,0],y0,y1,z0,z1);face(0,x0,[-1,0,0],y0,y1,z0,z1);
    face(1,y1,[0,1,0],x0,x1,z0,z1);face(1,y0,[0,-1,0],x0,x1,z0,z1);
  });
  return {parts,pts};
}
const M = buildModel();
const rotY=(v,a)=>{const c=Math.cos(a),s=Math.sin(a);return[v[0]*c+v[2]*s,v[1],-v[0]*s+v[2]*c]};
const rotX=(v,a)=>{const c=Math.cos(a),s=Math.sin(a);return[v[0],v[1]*c-v[2]*s,v[1]*s+v[2]*c]};
const rotZ=(v,a,px,py)=>{const c=Math.cos(a),s=Math.sin(a),x=v[0]-px,y=v[1]-py;return[px+x*c-y*s,py+x*s+y*c,v[2]]};
const hex=h=>{h=h.replace('#','');return[parseInt(h.slice(0,2),16),parseInt(h.slice(2,4),16),parseInt(h.slice(4,6),16)]};

window.mountClawdNV = function(cv, opt={}){
  const X=cv.getContext('2d'); let rgb=hex(opt.color||'#4fc36a'), raf=0, t0=performance.now();
  const T=document.createElement('canvas'), TX=T.getContext('2d');
  function draw(t){
    const dpr=Math.min(2,devicePixelRatio||1), W=cv.clientWidth, H=cv.clientHeight;
    if(cv.width!==W*dpr||cv.height!==H*dpr){cv.width=T.width=W*dpr;cv.height=T.height=H*dpr;}
    X.setTransform(dpr,0,0,dpr,0,0); TX.setTransform(dpr,0,0,dpr,0,0);
    const CW=Math.max(3,Math.round(W/34)), CH=Math.round(CW*1.5);   // 字格跟著尺寸走
    const cols=Math.ceil(W/CW), rows=Math.ceil(H/CH), N=cols*rows;
    const zb=new Float32Array(N).fill(-1e9), bb=new Float32Array(N).fill(-1), gb=new Int16Array(N).fill(-1);
    const scale=Math.min(W/19, H/13.5), D=34, cx=W/2, cy=H*0.47;
    const yaw=Math.sin(t*0.7)*0.62, pitch=0.26;                     // 左右擺頭，不整圈轉，小尺寸才認得出
    const walk=t*5, bob=Math.abs(Math.sin(walk))*0.2, blink=(t%3.7)>3.55;
    const L=[-0.5,0.7,0.6].map(x=>x/1.0488);
    for(const q of M.pts){
      const P=M.parts[q.pi]; let v=q.p.slice(), n=q.n;
      if(P.pivot){const s=P.name==='armL'?1:-1;const a=s*(Math.sin(t*3.1)*0.3+(P.name==='armR'?Math.max(0,Math.sin(t*0.9))*0.9:0));v=rotZ(v,a,P.pivot[0],P.pivot[1]);n=rotZ(n,a,0,0);}
      if(P.phase!==undefined){v[1]+=Math.max(0,Math.sin(walk+P.phase*Math.PI))*0.5;}
      v[1]+=bob; v=rotX(rotY(v,yaw),pitch); n=rotX(rotY(n,yaw),pitch);
      if(n[2]<-0.05) continue;
      const f=D/(D-v[2]), sx=cx+v[0]*scale*f, sy=cy-v[1]*scale*f, ci=(sx/CW)|0, ri=(sy/CH)|0;
      if(ci<0||ri<0||ci>=cols||ri>=rows) continue;
      const i=ri*cols+ci; if(v[2]<=zb[i]) continue;
      zb[i]=v[2]; gb[i]=q.g;
      bb[i]=(q.eye&&!blink)?-0.5:0.08+Math.max(0,n[2])**2*0.55+Math.max(0,n[0]*L[0]+n[1]*L[1]+n[2]*L[2])*0.42;
    }
    TX.clearRect(0,0,W,H); TX.font=`${CH-1}px Menlo, monospace`; TX.textBaseline='top';
    const tick=(t*6)|0, [r,g,b]=rgb;
    for(let i=0;i<N;i++){const v=bb[i]; if(v<0) continue;
      const gl=gb[i], x=(i%cols)*CW, y=((i/cols)|0)*CH;
      const ch=(v>0.3&&(gl+(tick>>1))%4===0)?GLYPHS[(gl+tick)%GLYPHS.length]:RAMP[Math.min(RAMP.length-1,(v*RAMP.length)|0)];
      const k=Math.min(1,v), hi=((gl*31+tick*17+i)%41===0);
      TX.fillStyle=hi?`rgb(${Math.min(255,r+150)},${Math.min(255,g+90)},${Math.min(255,b+150)})`:`rgba(${r*(0.55+k*0.6)|0},${g*(0.55+k*0.55)|0},${b*(0.55+k*0.6)|0},${0.72+k*0.28})`;
      TX.fillText(ch,x,y);
    }
    X.clearRect(0,0,W,H);
    const fl=0.9+Math.random()*0.1;
    X.globalAlpha=0.7*fl; X.filter=`blur(${Math.max(2,CW*0.8)}px)`; X.drawImage(T,0,0,W,H);  // 磷光暈
    X.filter='none'; X.globalAlpha=fl; X.drawImage(T,0,0,W,H);
    X.globalAlpha=1;
    X.globalCompositeOperation='destination-out'; X.fillStyle='rgba(0,0,0,0.35)';         // 掃描線（只在娃娃上）
    for(let y=(t*20)%3;y<H;y+=3) X.fillRect(0,y,W,1);
    X.globalCompositeOperation='source-over';
  }
  let last=0;
  const loop=now=>{ raf=requestAnimationFrame(loop);
    if(now-last<33) return; last=now;                                  // 30fps 就夠
    if(cv.style.display==='none'||!cv.isConnected||!cv.clientWidth) return; // 看不見就不畫
    draw((now-t0)/1000); };
  if(opt.t!=null) draw(opt.t); else raf=requestAnimationFrame(loop);
  return { setColor(h){rgb=hex(h);}, stop(){cancelAnimationFrame(raf);} };
};
})();
