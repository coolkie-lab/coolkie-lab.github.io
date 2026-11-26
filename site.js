/* Coolkie : thème et contenus modifiables depuis la gestion (table site_settings). */
(function(){
const C=window.COOLKIE||{};
const DEF={primary:'#2f8fd0',ink:'#123047',surface:'#effafd',bg:'#dcf1f9',fontTitle:'Outfit',fontBody:'Inter'};
const PRESETS={'Ciel (conseillé)':{primary:'#2f8fd0',ink:'#123047',surface:'#effafd',bg:'#dcf1f9'},'Glacier, plus clair':{primary:'#62b9e6',ink:'#123047',surface:'#f3fbfe',bg:'#dcf1f9'},'Lagon':{primary:'#1d9bb2',ink:'#0f2f3a',surface:'#effafd',bg:'#dcf1f9'},'Bleu nuit':{primary:'#2554d9',ink:'#0f1f3d',surface:'#f1f5ff',bg:'#ffffff'}};
function lum(hex){const n=parseInt(hex.slice(1),16),f=c=>{c/=255;return c<=.03928?c/12.92:Math.pow((c+.055)/1.055,2.4)};return .2126*f(n>>16)+.7152*f(n>>8&255)+.0722*f(n&255)}
const FONTS=['Outfit','Inter','Fredoka','Poppins','DM Sans','Nunito','Playfair Display','DM Serif Display'];
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const rich=t=>esc(t).replace(/\*\*(.+?)\*\*/g,'<b>$1</b>').replace(/\n/g,'<br>');
function mix(hex,pct){const n=parseInt(hex.slice(1),16),r=n>>16,g=n>>8&255,b=n&255,m=x=>Math.round(x+(255-x)*pct);return'#'+[m(r),m(g),m(b)].map(x=>x.toString(16).padStart(2,'0')).join('')}
function okHex(v){return/^#[0-9a-f]{6}$/i.test(v||'')}
function theme(t){t={...DEF,...(t||{})};const s=document.documentElement.style;
  const p=okHex(t.primary)?t.primary:DEF.primary,ink=okHex(t.ink)?t.ink:DEF.ink,sf=okHex(t.surface)?t.surface:DEF.surface,bg=okHex(t.bg)?t.bg:DEF.bg;
  s.setProperty('--ice',p);s.setProperty('--doughDeep',p);s.setProperty('--iceBg',mix(p,.9));s.setProperty('--ink',ink);s.setProperty('--onP',lum(p)>.33?ink:'#ffffff');s.setProperty('--line',mix(p,.84));s.setProperty('--dough',sf);s.setProperty('--bg',bg);
  const ft=FONTS.includes(t.fontTitle)?t.fontTitle:DEF.fontTitle,fb=FONTS.includes(t.fontBody)?t.fontBody:DEF.fontBody;
  s.setProperty('--fT',`"${ft}",system-ui,sans-serif`);s.setProperty('--fB',`"${fb}",system-ui,sans-serif`);
  const fam=[...new Set([ft,fb])].filter(f=>f!=='Outfit'&&f!=='Inter');
  if(fam.length){const id='ck-fonts';let l=document.getElementById(id);if(!l){l=document.createElement('link');l.id=id;l.rel='stylesheet';document.head.appendChild(l)}
    l.href='https://fonts.googleapis.com/css2?'+fam.map(f=>'family='+f.replace(/ /g,'+')+':wght@400;500;600;700').join('&')+'&display=swap'}}
function safeUrl(u){return/^(img\/[\w.-]+|https:\/\/[\w.-]+\.supabase\.co\/storage\/v1\/object\/public\/[\w\/.%-]+)$/.test(u||'')?u:''}
function banner(b){if(/gestion/.test(location.pathname))return;let e=document.getElementById('ck-banner');if(!b||!b.on||!(b.text||'').trim()){if(e)e.remove();return}
  if(!e){e=document.createElement('div');e.id='ck-banner';e.className='ck-banner';document.body.prepend(e)}
  const u=/^(https:\/\/|\.\/|[\w-]+\.html)/.test(b.link||'')?b.link:'';e.innerHTML=u?`<a href="${esc(u)}">${rich(b.text)}</a>`:rich(b.text)}
function content(d){if(!d)return;banner(d.banner);const T=d.texts||{},I=d.images||{};
  document.querySelectorAll('[data-c]').forEach(e=>{const v=T[e.dataset.c];if(typeof v==='string'&&v.trim())e.innerHTML=rich(v)});
  document.querySelectorAll('[data-img]').forEach(e=>{const u=safeUrl(I[e.dataset.img]);if(!u)return;if(e.tagName==='IMG')e.src=u;else e.style.backgroundImage=`url('${u}')`})}
let cache=null;try{cache=JSON.parse(localStorage.getItem('ck_site')||'null')}catch(e){}
theme(cache&&cache.theme);
const ready=f=>document.readyState==='loading'?document.addEventListener('DOMContentLoaded',f):f();
if(cache)ready(()=>content(cache));
window.CK_SITE={DEF,PRESETS,FONTS,theme,content,rich,safeUrl,banner};
if(window.CK_NO_FETCH||!C.supabaseUrl)return;
fetch(C.supabaseUrl+'/rest/v1/site_settings?id=eq.main&select=data',{headers:{apikey:C.supabaseKey,Authorization:'Bearer '+C.supabaseKey}})
  .then(r=>r.ok?r.json():null).then(r=>{const d=r&&r[0]&&r[0].data||{};try{localStorage.setItem('ck_site',JSON.stringify(d))}catch(e){}
    theme(d.theme);ready(()=>content(d))}).catch(()=>{});
})();
