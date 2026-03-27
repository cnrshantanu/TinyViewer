import CryptoKit
import Foundation
import Network

// MARK: - HTML templates

private let pinPageTemplate = """
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Tiny Viewer</title>
  <style>
    *{box-sizing:border-box}
    body{margin:0;background:#111;display:flex;justify-content:center;align-items:center;min-height:100vh;font-family:-apple-system,sans-serif}
    .card{background:#1c1c1e;border-radius:16px;padding:2rem;width:300px;display:flex;flex-direction:column;gap:1rem}
    h2{color:#fff;margin:0;text-align:center;font-size:1.1rem}
    input{padding:.75rem;border-radius:10px;border:1px solid #3a3a3c;background:#2c2c2e;color:#fff;font-size:1.4rem;letter-spacing:.3rem;text-align:center;outline:none;width:100%}
    input:focus{border-color:#0a84ff}
    button{padding:.75rem;border-radius:10px;border:none;background:#0a84ff;color:#fff;font-size:1rem;font-weight:600;cursor:pointer;width:100%}
    .err{color:#ff453a;text-align:center;font-size:.85rem}
  </style>
</head>
<body>
  <div class="card">
    <h2>&#x1F5A5; Tiny Viewer</h2>
    <form method="POST" action="/auth">
      <input type="hidden" name="pending" value="%%PENDING%%">
      <input type="password" name="pin" placeholder="PIN" autofocus autocomplete="off" maxlength="16">
      <button type="submit">Connect</button>
    </form>
    %%ERROR%%
  </div>
</body>
</html>
"""

private let viewerHTML = """
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Tiny Viewer</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{width:100%;height:100%;background:#000;overflow:hidden;cursor:none}
    img{width:100%;height:100%;object-fit:contain;display:block;user-select:none;-webkit-user-drag:none}
    #toolbar{position:fixed;top:10px;right:10px;display:flex;gap:4px;z-index:10;opacity:0;transition:opacity .25s}
    #toolbar.vis{opacity:1}
    .tbtn{background:rgba(0,0,0,.65);color:#aaa;border:1px solid #444;border-radius:6px;padding:4px 9px;font-size:11px;font-family:-apple-system,sans-serif;cursor:pointer;transition:background .15s,color .15s}
    .tbtn:hover{background:rgba(40,40,40,.9);color:#fff}
    .tbtn.lit{background:#0a84ff;color:#fff;border-color:#0a84ff}
    .tsep{width:1px;background:#444;margin:0 2px}
    #status{position:fixed;bottom:8px;left:8px;z-index:20;display:flex;flex-direction:column;align-items:flex-start;gap:4px}
    #dbgPanel{display:none;background:rgba(0,0,0,.7);color:#0f0;font:11px/1.4 'SF Mono',monospace;padding:6px 8px;border-radius:6px;pointer-events:none;white-space:nowrap}
    #dbgPanel.open{display:block}
    #pill{display:flex;align-items:center;gap:5px;background:rgba(0,0,0,.55);border:1px solid rgba(255,255,255,.12);border-radius:100px;padding:3px 8px;cursor:pointer;font:11px -apple-system,sans-serif;color:rgba(255,255,255,.7)}
    #dot{width:6px;height:6px;border-radius:50%;background:#888;flex-shrink:0}
    #dot.green{background:#30d158;box-shadow:0 0 4px #30d158}
    #dot.orange{background:#ff9f0a;box-shadow:0 0 4px #ff9f0a}
    #dot.red{background:#ff453a;box-shadow:0 0 4px #ff453a}
  </style>
</head>
<body>
  <img id="s" draggable="false">
  <div id="status">
    <div id="dbgPanel"></div>
    <div id="pill" onclick="toggleDbg()"><div id="dot"></div><span id="pillTxt">Connecting…</span></div>
  </div>
  <div id="toolbar">
    <button class="tbtn lit" id="qualityBtn" onclick="cycleQuality()">Med</button>
    <div class="tsep"></div>
    <button class="tbtn" onclick="sendShortcut('Tab','Tab',false,true,false,false)" title="⌘Tab — switch apps on remote Mac">⌘⇥</button>
    <button class="tbtn" onclick="sendShortcut(' ','Space',false,true,false,false)" title="⌘Space — Spotlight">⌘␣</button>
    <button class="tbtn" onclick="sendPaste()" title="Paste local clipboard into remote Mac">Paste</button>
    <div class="tsep"></div>
    <button class="tbtn" onclick="window.open('/terminal','_blank')">Terminal</button>
    <button class="tbtn" onclick="resetSession()" title="Release stuck keys/mouse and reconnect">↺</button>
  </div>
  <script>
    const img = document.getElementById('s');
    const dot = document.getElementById('dot');
    const pillTxt = document.getElementById('pillTxt');
    const dbgPanel = document.getElementById('dbgPanel');
    let dbgOpen = false;

    function toggleDbg() { dbgOpen = !dbgOpen; dbgPanel.className = dbgOpen ? 'open' : ''; }

    // ── Toolbar auto-hide ──────────────────────────────────────────────────────
    const toolbar = document.getElementById('toolbar');
    let hideTimer = null;
    function showToolbar() {
      toolbar.classList.add('vis');
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => toolbar.classList.remove('vis'), 2500);
    }
    document.addEventListener('mousemove', showToolbar);
    document.addEventListener('touchstart', showToolbar, {passive:true});

    // ── Coordinate normaliser ──────────────────────────────────────────────────
    function norm(cx, cy) {
      const r  = img.getBoundingClientRect();
      const iw = img.naturalWidth  || r.width;
      const ih = img.naturalHeight || r.height;
      const sc = Math.min(r.width / iw, r.height / ih);
      const dw = iw * sc, dh = ih * sc;
      const ox = (r.width  - dw) / 2;
      const oy = (r.height - dh) / 2;
      return {
        x: Math.max(0, Math.min(1, (cx - r.left - ox) / dw)),
        y: Math.max(0, Math.min(1, (cy - r.top  - oy) / dh))
      };
    }

    // ── Stats ──────────────────────────────────────────────────────────────────
    let frameN = 0, fpsTick = 0, rttMs = 0, frameKB = 0;
    let lowFpsCount = 0, highFpsCount = 0, lastAutoChange = 0;
    const AUTO_COOLDOWN = 8000;
    const qualities = ['Low','Medium','High'], qualityLabels = ['Low','Med','High'];
    let qualityIdx = 1, userQualityIdx = 1;

    function updateQualityBtn() {
      const lbl = qualityLabels[qualityIdx] + (qualityIdx < userQualityIdx ? '↓' : '');
      document.getElementById('qualityBtn').textContent = lbl;
      document.getElementById('qualityBtn').className = 'tbtn lit';
    }

    setInterval(() => {
      const fps = fpsTick, now = Date.now();
      if (now - lastAutoChange > AUTO_COOLDOWN) {
        if (fps < 8 && qualityIdx > 0) {
          if (++lowFpsCount >= 3) { qualityIdx--; send({type:'quality',quality:qualities[qualityIdx]}); updateQualityBtn(); lowFpsCount=0; highFpsCount=0; lastAutoChange=now; }
        } else if (fps > 11 && qualityIdx < userQualityIdx) {
          if (++highFpsCount >= 5) { qualityIdx++; send({type:'quality',quality:qualities[qualityIdx]}); updateQualityBtn(); highFpsCount=0; lowFpsCount=0; lastAutoChange=now; }
        } else { if(fps>=8)lowFpsCount=0; if(fps<=11)highFpsCount=0; }
      }
      dbgPanel.textContent = '#'+frameN+'  '+fps+'fps  rtt:'+rttMs+'ms  '+frameKB+'KB  '+qualityLabels[qualityIdx];
      fpsTick = 0;
    }, 1000);

    // ── WebSocket ──────────────────────────────────────────────────────────────
    const wsProto = location.protocol==='https:'?'wss:':'ws:';
    let ws, wsReady=false, frameRequested=false, frameReadySentAt=0, prevFrameUrl=null;

    function requestFrame() {
      if (!wsReady || frameRequested) return;
      frameRequested = true; frameReadySentAt = Date.now();
      ws.send(JSON.stringify({type:'frameReady'}));
    }
    setInterval(() => { if(frameRequested && Date.now()-frameReadySentAt>200) frameRequested=false; requestFrame(); }, 100);

    function connectWS() {
      ws = new WebSocket(wsProto+'//'+location.host+'/ws');
      ws.binaryType = 'blob';
      ws.onopen  = () => { wsReady=true; dot.className='green'; pillTxt.textContent='Live'; requestFrame(); };
      ws.onclose = () => { wsReady=false; frameRequested=false; dot.className='orange'; pillTxt.textContent='Reconnecting…'; setTimeout(connectWS,1500); };
      ws.onerror = () => {};
      ws.onmessage = e => {
        if (!(e.data instanceof Blob)) return;
        rttMs = Date.now()-frameReadySentAt; frameKB=Math.round(e.data.size/1024);
        frameRequested=false; requestFrame();
        frameN=frameN%60+1; fpsTick++;
        if(prevFrameUrl)URL.revokeObjectURL(prevFrameUrl);
        prevFrameUrl=URL.createObjectURL(e.data); img.src=prevFrameUrl;
      };
    }
    connectWS();

    // ── Send helpers ───────────────────────────────────────────────────────────
    let eventBatch=[], flushHandle=null;
    function flushBatch() { flushHandle=null; if(!eventBatch.length)return; const b=eventBatch.splice(0); fetch('/event',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}).catch(()=>{}); }
    function send(data) { if(wsReady){ws.send(JSON.stringify(data));}else{eventBatch.push(data);if(!flushHandle)flushHandle=setTimeout(flushBatch,50);} }

    // ── Reset ──────────────────────────────────────────────────────────────────
    function releaseAllButtons() {
      heldButtons.forEach(b => send({type:'mouseup',x:0,y:0,button:b}));
      heldButtons.clear();
      ['Shift','Control','Alt','Meta'].forEach(k => send({type:'keyup',key:k,code:'',shift:false,meta:false,alt:false,ctrl:false}));
    }
    function resetSession() { releaseAllButtons(); ws.close(); }

    // Send a one-shot key combo (for OS-intercepted shortcuts like ⌘Tab, ⌘Space)
    function sendShortcut(key, code, shift, meta, alt, ctrl) {
      send({type:'keydown',key,code,shift,meta,alt,ctrl});
      setTimeout(() => send({type:'keyup',key,code,shift,meta,alt,ctrl}), 80);
    }

    // Paste local clipboard text into the remote Mac character by character
    async function sendPaste() {
      let text = '';
      try { text = await navigator.clipboard.readText(); }
      catch(e) { text = prompt('Paste text to send:') || ''; }
      if (!text) return;
      for (const char of text) {
        send({type:'keydown',key:char,code:'',shift:false,meta:false,alt:false,ctrl:false});
        send({type:'keyup',  key:char,code:'',shift:false,meta:false,alt:false,ctrl:false});
      }
    }

    window.addEventListener('blur',  releaseAllButtons);
    document.addEventListener('visibilitychange', () => { if(document.hidden) releaseAllButtons(); });

    // ── Mouse ──────────────────────────────────────────────────────────────────
    const heldButtons = new Set();
    let lastMove = 0;
    img.addEventListener('mousemove', e => {
      const now=Date.now(); if(now-lastMove<33)return; lastMove=now;
      const {x,y}=norm(e.clientX,e.clientY); send({type:'mousemove',x,y});
    });
    img.addEventListener('mousedown', e => {
      e.preventDefault(); heldButtons.add(e.button);
      const {x,y}=norm(e.clientX,e.clientY); send({type:'mousedown',x,y,button:e.button});
    });
    window.addEventListener('mouseup', e => {
      heldButtons.delete(e.button);
      const {x,y}=norm(e.clientX,e.clientY); send({type:'mouseup',x,y,button:e.button});
    });
    img.addEventListener('contextmenu', e => e.preventDefault());
    img.addEventListener('dragstart',   e => e.preventDefault());
    img.addEventListener('wheel', e => { e.preventDefault(); send({type:'wheel',dx:e.deltaX,dy:e.deltaY}); }, {passive:false});

    // ── Quality ────────────────────────────────────────────────────────────────
    function cycleQuality() {
      userQualityIdx=(userQualityIdx+1)%qualities.length; qualityIdx=userQualityIdx;
      updateQualityBtn(); send({type:'quality',quality:qualities[qualityIdx]});
      lowFpsCount=0; highFpsCount=0; lastAutoChange=0;
    }

    // ── Keyboard ───────────────────────────────────────────────────────────────
    document.addEventListener('click', () => document.body.focus());
    document.addEventListener('keydown', e => { e.preventDefault(); send({type:'keydown',key:e.key,code:e.code,shift:e.shiftKey,meta:e.metaKey,alt:e.altKey,ctrl:e.ctrlKey}); });
    document.addEventListener('keyup',   e => { send({type:'keyup',key:e.key,code:e.code,shift:e.shiftKey,meta:e.metaKey,alt:e.altKey,ctrl:e.ctrlKey}); });
  </script>
</body>
</html>
"""

private let h264HTMLTemplate = """
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Tiny Viewer</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{width:100%;height:100%;background:#000;overflow:hidden;cursor:none}
    canvas{width:100%;height:100%;object-fit:contain;display:block}
    #toolbar{position:fixed;top:10px;right:10px;display:flex;gap:4px;z-index:10;opacity:0;transition:opacity .25s}
    #toolbar.vis{opacity:1}
    .tbtn{background:rgba(0,0,0,.65);color:#aaa;border:1px solid #444;border-radius:6px;padding:4px 9px;font-size:11px;font-family:-apple-system,sans-serif;cursor:pointer;transition:background .15s,color .15s}
    .tbtn:hover{background:rgba(40,40,40,.9);color:#fff}
    .tbtn.lit{background:#0a84ff;color:#fff;border-color:#0a84ff}
    .tsep{width:1px;background:#444;margin:0 2px}
    #status{position:fixed;bottom:8px;left:8px;z-index:20;display:flex;flex-direction:column;align-items:flex-start;gap:4px}
    #dbgPanel{display:none;background:rgba(0,0,0,.7);color:#0f0;font:11px/1.4 'SF Mono',monospace;padding:6px 8px;border-radius:6px;pointer-events:none;white-space:nowrap}
    #dbgPanel.open{display:block}
    #pill{display:flex;align-items:center;gap:5px;background:rgba(0,0,0,.55);border:1px solid rgba(255,255,255,.12);border-radius:100px;padding:3px 8px;cursor:pointer;font:11px -apple-system,sans-serif;color:rgba(255,255,255,.7)}
    #dot{width:6px;height:6px;border-radius:50%;background:#888;flex-shrink:0}
    #dot.green{background:#30d158;box-shadow:0 0 4px #30d158}
    #dot.orange{background:#ff9f0a;box-shadow:0 0 4px #ff9f0a}
    #dot.red{background:#ff453a;box-shadow:0 0 4px #ff453a}
  </style>
</head>
<body>
  <canvas id="c"></canvas>
  <div id="status">
    <div id="dbgPanel"></div>
    <div id="pill" onclick="toggleDbg()"><div id="dot"></div><span id="pillTxt">Connecting…</span></div>
  </div>
  <div id="toolbar">
    <button class="tbtn lit" id="qualityBtn" onclick="cycleQuality()">Med</button>
    <div class="tsep"></div>
    <button class="tbtn" onclick="sendShortcut('Tab','Tab',false,true,false,false)" title="⌘Tab — switch apps on remote Mac">⌘⇥</button>
    <button class="tbtn" onclick="sendShortcut(' ','Space',false,true,false,false)" title="⌘Space — Spotlight">⌘␣</button>
    <button class="tbtn" onclick="sendPaste()" title="Paste local clipboard into remote Mac">Paste</button>
    <div class="tsep"></div>
    <button class="tbtn" onclick="window.open('/terminal','_blank')">Terminal</button>
    <button class="tbtn" onclick="resetSession()" title="Release stuck keys/mouse and reconnect">↺</button>
  </div>
  <script>
    const canvas = document.getElementById('c');
    const ctx    = canvas.getContext('2d');
    const dot    = document.getElementById('dot');
    const pillTxt = document.getElementById('pillTxt');
    const dbgPanel = document.getElementById('dbgPanel');
    let dbgOpen = false;
    function toggleDbg() { dbgOpen=!dbgOpen; dbgPanel.className=dbgOpen?'open':''; }

    const toolbar = document.getElementById('toolbar');
    let hideTimer=null;
    function showToolbar(){ toolbar.classList.add('vis'); clearTimeout(hideTimer); hideTimer=setTimeout(()=>toolbar.classList.remove('vis'),2500); }
    document.addEventListener('mousemove', showToolbar);

    // WebCodecs H.264 decoder
    let decoder, pendingConfig=null, frameCount=0, fps=0, fpsTick=0, rttMs=0, frameKB=0;
    setInterval(()=>{ fps=fpsTick; fpsTick=0; dbgPanel.textContent='#'+frameCount+'  '+fps+'fps  rtt:'+rttMs+'ms  '+frameKB+'KB'; }, 1000);

    function initDecoder() {
      if(decoder){ try{decoder.close();}catch(e){} }
      decoder = new VideoDecoder({
        output: frame => {
          canvas.width=frame.displayWidth; canvas.height=frame.displayHeight;
          ctx.drawImage(frame,0,0); frame.close(); frameCount++; fpsTick++;
        },
        error: e => { console.error('VideoDecoder',e); setTimeout(initDecoder,500); }
      });
      if(pendingConfig) decoder.configure(pendingConfig);
    }

    if(typeof VideoDecoder!=='undefined') initDecoder();
    else { pillTxt.textContent='WebCodecs not supported'; dot.className='red'; }

    // WebSocket
    const wsProto=location.protocol==='https:'?'wss:':'ws:';
    let ws, wsReady=false;
    let sendBuf=[], sendTimer=null;
    function flushSend(){ sendTimer=null; if(!sendBuf.length)return; const b=sendBuf.splice(0); fetch('/event',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}).catch(()=>{}); }
    function send(d){ if(wsReady){ws.send(JSON.stringify(d));}else{sendBuf.push(d);if(!sendTimer)sendTimer=setTimeout(flushSend,50);} }

    function connectWS(){
      ws=new WebSocket(wsProto+'//'+location.host+'/ws');
      ws.binaryType='arraybuffer';
      ws.onopen=()=>{ wsReady=true; dot.className='green'; pillTxt.textContent='Live (H.264)'; };
      ws.onclose=()=>{ wsReady=false; dot.className='orange'; pillTxt.textContent='Reconnecting…'; setTimeout(connectWS,1500); };
      ws.onerror=()=>{};
      ws.onmessage=e=>{
        if(typeof e.data==='string'){
          try{
            const msg=JSON.parse(e.data);
            if(msg.type==='config' && typeof VideoDecoder!=='undefined'){
              pendingConfig={codec:'avc1.'+msg.profileLevelId, optimizeForLatency:true};
              initDecoder();
            }
          }catch(err){}
          return;
        }
        const sentAt=ws._sentAt||Date.now();
        rttMs=Date.now()-sentAt; frameKB=Math.round(e.data.byteLength/1024);
        if(!decoder||decoder.state==='closed') return;
        const view=new Uint8Array(e.data);
        const isKey=(view[4]&0x1f)===5;
        if(decoder.state==='unconfigured') return;
        try{
          ws._sentAt=Date.now();
          decoder.decode(new EncodedVideoChunk({type:isKey?'key':'delta',timestamp:Date.now()*1000,data:e.data}));
        }catch(err){}
      };
    }
    connectWS();

    function releaseAllButtons(){
      heldButtons.forEach(b=>send({type:'mouseup',x:0,y:0,button:b}));
      heldButtons.clear();
      ['Shift','Control','Alt','Meta'].forEach(k=>send({type:'keyup',key:k,code:'',shift:false,meta:false,alt:false,ctrl:false}));
    }
    function resetSession(){ releaseAllButtons(); ws.close(); }
    function sendShortcut(key,code,shift,meta,alt,ctrl){
      send({type:'keydown',key,code,shift,meta,alt,ctrl});
      setTimeout(()=>send({type:'keyup',key,code,shift,meta,alt,ctrl}),80);
    }
    async function sendPaste(){
      let text='';
      try{text=await navigator.clipboard.readText();}
      catch(e){text=prompt('Paste text to send:')||'';}
      if(!text)return;
      for(const char of text){
        send({type:'keydown',key:char,code:'',shift:false,meta:false,alt:false,ctrl:false});
        send({type:'keyup',  key:char,code:'',shift:false,meta:false,alt:false,ctrl:false});
      }
    }
    window.addEventListener('blur', releaseAllButtons);
    document.addEventListener('visibilitychange',()=>{ if(document.hidden) releaseAllButtons(); });

    function norm(cx,cy){
      const r=canvas.getBoundingClientRect();
      return { x:Math.max(0,Math.min(1,(cx-r.left)/r.width)), y:Math.max(0,Math.min(1,(cy-r.top)/r.height)) };
    }
    const heldButtons=new Set();
    let lastMove=0;
    canvas.addEventListener('mousemove',e=>{ const now=Date.now(); if(now-lastMove<33)return; lastMove=now; const{x,y}=norm(e.clientX,e.clientY); send({type:'mousemove',x,y}); });
    canvas.addEventListener('mousedown',e=>{ e.preventDefault(); heldButtons.add(e.button); const{x,y}=norm(e.clientX,e.clientY); send({type:'mousedown',x,y,button:e.button}); });
    window.addEventListener('mouseup',e=>{ heldButtons.delete(e.button); const{x,y}=norm(e.clientX,e.clientY); send({type:'mouseup',x,y,button:e.button}); });
    canvas.addEventListener('contextmenu',e=>e.preventDefault());
    canvas.addEventListener('wheel',e=>{ e.preventDefault(); send({type:'wheel',dx:e.deltaX,dy:e.deltaY}); },{passive:false});

    const qualities=['Low','Medium','High'],qualityLabels=['Low','Med','High'];
    let qualityIdx=1,userQualityIdx=1;
    function updateQualityBtn(){ document.getElementById('qualityBtn').textContent=qualityLabels[qualityIdx]+(qualityIdx<userQualityIdx?'↓':''); document.getElementById('qualityBtn').className='tbtn lit'; }
    function cycleQuality(){ userQualityIdx=(userQualityIdx+1)%qualities.length; qualityIdx=userQualityIdx; updateQualityBtn(); send({type:'quality',quality:qualities[qualityIdx]}); }

    document.addEventListener('click',()=>document.body.focus());
    document.addEventListener('keydown',e=>{ e.preventDefault(); send({type:'keydown',key:e.key,code:e.code,shift:e.shiftKey,meta:e.metaKey,alt:e.altKey,ctrl:e.ctrlKey}); });
    document.addEventListener('keyup',e=>{ send({type:'keyup',key:e.key,code:e.code,shift:e.shiftKey,meta:e.metaKey,alt:e.altKey,ctrl:e.ctrlKey}); });
  </script>
</body>
</html>
"""

private let terminalHTML = """
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Terminal — Tiny Viewer</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.min.css">
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{width:100%;height:100%;background:#1a1a1a;overflow:hidden}
    #term{width:100%;height:100%}
  </style>
</head>
<body>
  <div id="term"></div>
  <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.min.js"></script>
  <script>
    const term = new Terminal({ cursorBlink:true, fontSize:14, fontFamily:"'SF Mono',Menlo,monospace", theme:{background:'#1a1a1a'} });
    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(document.getElementById('term'));
    fitAddon.fit();

    const wsProto = location.protocol==='https:'?'wss:':'ws:';
    let ws, reconnectTimer=null;

    function connect() {
      ws = new WebSocket(wsProto+'//'+location.host+'/terminal-ws');
      ws.binaryType = 'arraybuffer';
      ws.onopen  = () => { term.write('\\r\\n\\x1b[32mConnected\\x1b[0m\\r\\n'); };
      ws.onclose = () => { term.write('\\r\\n\\x1b[31mDisconnected — reconnecting…\\x1b[0m\\r\\n'); reconnectTimer=setTimeout(connect,2000); };
      ws.onerror = () => {};
      ws.onmessage = e => {
        if (e.data instanceof ArrayBuffer) {
          term.write(new Uint8Array(e.data));
        }
      };
    }
    connect();

    term.onData(data => {
      if (ws && ws.readyState===WebSocket.OPEN) ws.send(new TextEncoder().encode(data));
    });

    function sendResize() {
      fitAddon.fit();
      if (ws && ws.readyState===WebSocket.OPEN) {
        ws.send(JSON.stringify({type:'resize',cols:term.cols,rows:term.rows}));
      }
    }
    window.addEventListener('resize', sendResize);
    setTimeout(sendResize, 300);
  </script>
</body>
</html>
"""

// MARK: - Parsed HTTP Request

private struct HTTPRequest {
    let method: String
    let cleanPath: String       // path without query string
    let connectToken: String?   // ?token= param for one-time auth
    let sessionToken: String?
    let body: String
    let webSocketKey: String?   // Sec-WebSocket-Key header for WS upgrade
}

private func parse(_ data: Data) -> HTTPRequest {
    let text  = String(bytes: data, encoding: .utf8) ?? ""
    let lines = text.components(separatedBy: "\r\n")

    let firstParts = (lines.first ?? "").components(separatedBy: " ")
    let method  = firstParts.count > 0 ? firstParts[0] : "GET"
    let rawPath = firstParts.count > 1 ? firstParts[1] : "/"

    // Split path and query string
    let pathParts   = rawPath.components(separatedBy: "?")
    let cleanPath   = pathParts[0]
    let queryString = pathParts.count > 1 ? pathParts[1] : ""

    // Extract ?token= from query string
    let connectToken: String? = queryString
        .components(separatedBy: "&")
        .compactMap { item -> String? in
            let kv = item.components(separatedBy: "=")
            guard kv.count == 2, kv[0] == "token", !kv[1].isEmpty else { return nil }
            return kv[1].removingPercentEncoding ?? kv[1]
        }
        .first

    var sessionToken: String? = nil
    var webSocketKey: String? = nil
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("cookie:") {
            let cookieStr = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            for pair in cookieStr.components(separatedBy: ";") {
                let kv = pair.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
                if kv.count == 2, kv[0] == "session" { sessionToken = kv[1] }
            }
        } else if lower.hasPrefix("sec-websocket-key:") {
            webSocketKey = String(line.dropFirst("sec-websocket-key:".count))
                .trimmingCharacters(in: .whitespaces)
        }
    }

    var body = ""
    if let range = text.range(of: "\r\n\r\n") {
        body = String(text[range.upperBound...])
    }

    return HTTPRequest(method: method, cleanPath: cleanPath,
                       connectToken: connectToken, sessionToken: sessionToken,
                       body: body, webSocketKey: webSocketKey)
}

// MARK: - MJPEG Server

class MJPEGServer {

    /// Set before calling start(). Empty string = no auth required.
    var pin: String = ""

    /// One-time connect token validator. When set, direct URL access without a valid token returns 403.
    nonisolated(unsafe) var tokenValidator: ((String) async -> Bool)?

    /// Connection mode — determines which viewer HTML is served at GET /.
    nonisolated(unsafe) var connectionMode: ConnectionMode = .relay

    nonisolated(unsafe) private var terminalSessions: [TerminalSession] = []

    private var listener: NWListener?

    nonisolated(unsafe) private var streamConnections: [NWConnection]          = []
    nonisolated(unsafe) private var wsConnections:     [NWConnection]          = []
    nonisolated(unsafe) private var validSessions:     Set<String>             = []
    nonisolated(unsafe) private var pendingSessions:   Set<String>             = []
    nonisolated(unsafe) private var latestFrame:       Data?                   = nil
    nonisolated(unsafe) private var latestFrameID:    UInt64                  = 0
    nonisolated(unsafe) private var latestImageData:  Data?                   = nil
    nonisolated(unsafe) private var wsVideoReady:     Set<ObjectIdentifier>   = []
    nonisolated(unsafe) private var busyClients:       Set<ObjectIdentifier>   = []
    nonisolated(unsafe) private var lastInputTime:     Date                    = .distantPast

    /// True when no input event has arrived for more than 3 seconds.
    nonisolated var isIdle: Bool { Date().timeIntervalSince(lastInputTime) > 3.0 }
    nonisolated let queue = DispatchQueue(label: "com.tinyviewer.mjpeg", qos: .userInitiated)

    nonisolated(unsafe) var onClientCountChanged: ((Int) -> Void)?
    nonisolated(unsafe) var onQualityChange: ((StreamQuality) -> Void)?

    // MARK: - Lifecycle

    func start() {
        validSessions.removeAll()
        pendingSessions.removeAll()
        latestFrame     = nil
        latestImageData = nil
        busyClients.removeAll()
        wsVideoReady.removeAll()
        lastInputTime = .distantPast
        do {
            listener = try NWListener(using: .tcp, on: 8080)
            listener?.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:         print("[MJPEGServer] Listening on :8080")
                case .failed(let e): print("[MJPEGServer] Listener failed: \(e)")
                default: break
                }
            }
            listener?.start(queue: queue)
        } catch {
            print("[MJPEGServer] Cannot create listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            self?.streamConnections.forEach { $0.cancel() }
            self?.streamConnections.removeAll()
            self?.wsConnections.forEach { $0.cancel() }
            self?.wsConnections.removeAll()
            self?.wsVideoReady.removeAll()
            self?.validSessions.removeAll()
            self?.pendingSessions.removeAll()
            self?.latestFrame     = nil
            self?.latestImageData = nil
            self?.busyClients.removeAll()
            self?.terminalSessions.forEach { $0.stop() }
            self?.terminalSessions.removeAll()
            self?.onClientCountChanged?(0)
        }
    }

    // MARK: - Accept & Route

    nonisolated private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { connection.cancel(); return }

            let req = parse(data)

            switch (req.method, req.cleanPath) {

            case ("GET", "/ws"):
                if self.isAuthorized(req.sessionToken) {
                    self.handleWebSocketUpgrade(connection, key: req.webSocketKey)
                } else {
                    self.send401(connection)
                }

            case ("GET", "/terminal"):
                if let tok = req.connectToken {
                    self.handleTokenAuth(connection, token: tok, redirectTo: "/terminal")
                } else if self.isAuthorized(req.sessionToken) {
                    self.send200(connection, html: terminalHTML)
                } else {
                    self.redirectToRoot(connection)
                }

            case ("GET", "/terminal-ws"):
                if self.isAuthorized(req.sessionToken) {
                    self.handleTerminalWSUpgrade(connection, key: req.webSocketKey)
                } else {
                    self.send401(connection)
                }

            case ("GET", _) where req.cleanPath.hasPrefix("/stream"):
                if self.isAuthorized(req.sessionToken) {
                    self.handleStream(connection)
                } else {
                    self.redirectToRoot(connection)
                }

            case ("POST", "/auth"):
                self.handleAuth(connection, body: req.body)

            case ("POST", "/event"):
                if self.isAuthorized(req.sessionToken) {
                    self.handleInputEvent(connection, body: req.body)
                } else {
                    self.send401(connection)
                }

            case ("POST", "/quality"):
                if self.isAuthorized(req.sessionToken) {
                    self.handleQualityChange(connection, body: req.body)
                } else {
                    self.send401(connection)
                }

            case ("GET", "/"):
                if let tok = req.connectToken {
                    self.handleTokenAuth(connection, token: tok)
                } else if self.isAuthorized(req.sessionToken) {
                    let html = self.connectionMode == .direct ? h264HTMLTemplate : viewerHTML
                    self.send200(connection, html: html)
                } else if self.tokenValidator != nil {
                    // Token validation always required — reject direct access without token
                    self.send403(connection)
                } else {
                    self.send200(connection, html: pinPageTemplate
                        .replacingOccurrences(of: "%%PENDING%%", with: "")
                        .replacingOccurrences(of: "%%ERROR%%", with: ""))
                }

            default:
                self.handle404(connection)
            }
        }
    }

    // MARK: - Auth

    nonisolated private func isAuthorized(_ token: String?) -> Bool {
        // When a tokenValidator is configured, a real session is always required —
        // the empty-PIN shortcut would bypass Firebase auth entirely.
        if tokenValidator != nil {
            guard let token else { return false }
            return validSessions.contains(token)
        }
        guard !pin.isEmpty else { return true }
        guard let token else { return false }
        return validSessions.contains(token)
    }

    nonisolated private func handleAuth(_ conn: NWConnection, body: String) {
        var params: [String: String] = [:]
        for part in body.components(separatedBy: "&") {
            let kv = part.components(separatedBy: "=")
            if kv.count == 2 {
                params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        let submitted = params["pin"] ?? ""
        let pending   = params["pending"].flatMap { $0.isEmpty ? nil : $0 }

        // When tokenValidator is set, a valid pending token is required
        if tokenValidator != nil {
            guard let pending, pendingSessions.contains(pending) else {
                send403(conn)
                return
            }
        }

        if pin.isEmpty || submitted == pin {
            let sessionTok = UUID().uuidString
            validSessions.insert(sessionTok)
            if let pending { pendingSessions.remove(pending) }
            let response = [
                "HTTP/1.1 302 Found",
                "Location: /",
                "Set-Cookie: session=\(sessionTok); Path=/; HttpOnly",
                "Content-Length: 0",
                "Connection: close",
                "", ""
            ].joined(separator: "\r\n")
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        } else {
            let pendingVal = pending ?? ""
            let errDiv = "<p class=\"err\">Incorrect PIN. Try again.</p>"
            let html = pinPageTemplate
                .replacingOccurrences(of: "%%PENDING%%", with: pendingVal)
                .replacingOccurrences(of: "%%ERROR%%", with: errDiv)
            send200(conn, html: html)
        }
    }

    // MARK: - Token Auth

    nonisolated private func handleTokenAuth(_ conn: NWConnection, token: String, redirectTo: String = "/") {
        guard let validator = tokenValidator else {
            // No validator configured — fall back to normal flow
            send200(conn, html: pinPageTemplate
                .replacingOccurrences(of: "%%PENDING%%", with: "")
                .replacingOccurrences(of: "%%ERROR%%", with: ""))
            return
        }
        Task {
            let valid = await validator(token)
            if valid {
                if self.pin.isEmpty {
                    // No PIN — grant full session immediately
                    let sessionTok = UUID().uuidString
                    self.queue.async { self.validSessions.insert(sessionTok) }
                    let response = [
                        "HTTP/1.1 302 Found",
                        "Location: \(redirectTo)",
                        "Set-Cookie: session=\(sessionTok); Path=/; HttpOnly",
                        "Content-Length: 0",
                        "Connection: close",
                        "", ""
                    ].joined(separator: "\r\n")
                    conn.send(content: response.data(using: .utf8),
                              completion: .contentProcessed { _ in conn.cancel() })
                } else {
                    // PIN required — issue pending token, show PIN page
                    let pendingTok = UUID().uuidString
                    self.queue.async { self.pendingSessions.insert(pendingTok) }
                    let html = pinPageTemplate
                        .replacingOccurrences(of: "%%PENDING%%", with: pendingTok)
                        .replacingOccurrences(of: "%%ERROR%%", with: "")
                    self.send200(conn, html: html)
                }
            } else {
                self.send403(conn)
            }
        }
    }

    // MARK: - Input Events

    nonisolated private func recordInput() {
        lastInputTime = Date()
    }

    nonisolated private func handleInputEvent(_ conn: NWConnection, body: String) {
        if let data = body.data(using: .utf8) {
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                array.forEach { InputController.shared.handleEvent($0) }
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                InputController.shared.handleEvent(json)
            }
        }
        recordInput()
        let response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - WebSocket

    nonisolated private func handleWebSocketUpgrade(_ conn: NWConnection, key: String?) {
        guard let key else { send400(conn); return }
        let magic  = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let hash   = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(hash).base64EncodedString()
        let resp   = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { conn.cancel(); return }
            self.queue.async {
                self.wsConnections.append(conn)
                self.wsVideoReady.insert(ObjectIdentifier(conn))
            }
            // Release any stuck mouse buttons / modifier keys from the previous session
            InputController.shared.releaseAll()
            self.readWSFrame(conn, buffer: [])
        })
    }

    nonisolated private func handleTerminalWSUpgrade(_ conn: NWConnection, key: String?) {
        guard let key else { send400(conn); return }
        let magic  = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let hash   = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(hash).base64EncodedString()
        let resp   = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { conn.cancel(); return }
            let session = TerminalSession(conn: conn, queue: self.queue)
            self.queue.async { self.terminalSessions.append(session) }
            session.onTerminated = { [weak self] in
                self?.queue.async { self?.terminalSessions.removeAll { $0 === session } }
            }
            session.start()
        })
    }

    nonisolated private func readWSFrame(_ conn: NWConnection, buffer: [UInt8]) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete else {
                self?.queue.async {
                    self?.wsConnections.removeAll { $0 === conn }
                    self?.wsVideoReady.remove(ObjectIdentifier(conn))
                }
                conn.cancel(); return
            }
            var buf = buffer
            if let data { buf.append(contentsOf: data) }
            self.processWSBuffer(conn, buffer: buf)
        }
    }

    nonisolated private func processWSBuffer(_ conn: NWConnection, buffer: [UInt8]) {
        var buf = buffer   // [UInt8] — always 0-based, no Data slice offset issues
        while buf.count >= 2 {
            let b0 = buf[0], b1 = buf[1]
            let opcode  = b0 & 0x0F
            let masked  = (b1 & 0x80) != 0
            var payLen  = Int(b1 & 0x7F)
            var idx     = 2
            if payLen == 126 {
                guard buf.count >= 4 else { break }
                payLen = Int(buf[2]) << 8 | Int(buf[3]); idx = 4
            } else if payLen == 127 {
                guard buf.count >= 10 else { break }
                payLen = Int(buf[6]) << 24 | Int(buf[7]) << 16 | Int(buf[8]) << 8 | Int(buf[9]); idx = 10
            }
            let maskLen  = masked ? 4 : 0
            let frameEnd = idx + maskLen + payLen
            guard buf.count >= frameEnd else { break }

            var payload = Array(buf[(idx + maskLen)..<frameEnd])
            if masked {
                let mk = Array(buf[idx..<(idx + 4)])
                for i in 0..<payload.count { payload[i] ^= mk[i % 4] }
            }
            buf.removeFirst(frameEnd)   // [UInt8].removeFirst reindexes to 0 — safe

            switch opcode {
            case 0x1, 0x2: // text or binary
                if let text = String(bytes: payload, encoding: .utf8),
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let msgType = json["type"] as? String
                    if msgType == "quality",
                       let str = json["quality"] as? String,
                       let q   = StreamQuality(rawValue: str) {
                        onQualityChange?(q)
                    } else if msgType == "frameReady" {
                        // Browser finished rendering — send latest frame immediately
                        wsVideoReady.insert(ObjectIdentifier(conn))
                        if let imageData = latestImageData {
                            sendWSVideoFrame(imageData, to: conn)
                        }
                    } else {
                        InputController.shared.handleEvent(json)
                        recordInput()
                    }
                }
            case 0x8: // close
                queue.async {
                    self.wsConnections.removeAll { $0 === conn }
                    self.wsVideoReady.remove(ObjectIdentifier(conn))
                }
                conn.cancel(); return
            case 0x9: // ping → pong
                conn.send(content: Data([0x8A, 0x00]), completion: .contentProcessed { _ in })
            default: break
            }
        }
        readWSFrame(conn, buffer: buf)
    }

    nonisolated private func handleQualityChange(_ conn: NWConnection, body: String) {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let str  = json["quality"] as? String,
           let q    = StreamQuality(rawValue: str) {
            onQualityChange?(q)
        }
        let r = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - MJPEG Stream

    nonisolated private func handleStream(_ conn: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache\r\nPragma: no-cache\r\nConnection: keep-alive\r\n\r\n"
        conn.send(content: headers.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { conn.cancel(); return }
            self.queue.async {
                self.streamConnections.append(conn)
                self.onClientCountChanged?(self.streamConnections.count)
            }
        })
    }

    // MARK: - Response Helpers

    nonisolated private func send200(_ conn: NWConnection, html: String) {
        let body    = html.data(using: .utf8)!
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = headers.data(using: .utf8)!
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func redirectToRoot(_ conn: NWConnection) {
        let r = "HTTP/1.1 302 Found\r\nLocation: /\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func send401(_ conn: NWConnection) {
        let r = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func handle404(_ conn: NWConnection) {
        let r = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func send400(_ conn: NWConnection) {
        let r = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func send403(_ conn: NWConnection) {
        let r = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Broadcast

    /// Returns "image/webp" or "image/jpeg" by inspecting magic bytes.
    private func mimeType(of data: Data) -> String {
        let h = data.prefix(4)
        if h.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if h.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return "image/jpeg"
    }

    /// Latest-frame-wins: each client only receives the newest frame once it
    /// finishes sending the previous one. No frames accumulate in the send buffer.
    nonisolated func broadcastFrame(_ imageData: Data) {
        let mime = mimeType(of: imageData)
        var frame = Data("--frame\r\nContent-Type: \(mime)\r\nContent-Length: \(imageData.count)\r\n\r\n".utf8)
        frame.append(imageData)
        frame.append(Data("\r\n".utf8))

        queue.async { [weak self] in
            guard let self else { return }
            self.latestFrameID &+= 1
            let fid = self.latestFrameID
            self.latestFrame     = frame
            self.latestImageData = imageData
            // MJPEG stream clients (legacy / test)
            for conn in self.streamConnections where !self.busyClients.contains(ObjectIdentifier(conn)) {
                self.sendFrame(frame, frameID: fid, to: conn)
            }
            // WS video clients — pull model, only send if browser has requested a frame
            for conn in self.wsConnections where self.wsVideoReady.contains(ObjectIdentifier(conn)) {
                self.sendWSVideoFrame(imageData, to: conn)
            }
        }
    }

    func broadcastH264Frame(_ annexB: Data, isKey: Bool) {
        queue.async { [weak self] in
            guard let self, !self.wsConnections.isEmpty else { return }
            for conn in self.wsConnections where self.wsVideoReady.contains(ObjectIdentifier(conn)) {
                self.sendWSVideoFrame(annexB, to: conn)
            }
        }
    }

    /// Wraps raw JPEG bytes in a WebSocket binary frame (opcode 0x2, no mask).
    private func buildWSBinaryFrame(_ data: Data) -> Data {
        let len = data.count
        var header = Data()
        header.append(0x82)   // FIN=1, opcode=2 (binary)
        if len < 126 {
            header.append(UInt8(len))
        } else if len <= 65535 {
            header.append(126)
            header.append(UInt8(len >> 8))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(127)
            for i in stride(from: 7, through: 0, by: -1) {
                header.append(UInt8((len >> (i * 8)) & 0xFF))
            }
        }
        var frame = header
        frame.append(data)
        return frame
    }

    /// Send a single image frame (WebP or JPEG) to a WS client. Marks the client as
    /// not-ready until it sends a frameReady message — pull-model backpressure.
    nonisolated private func sendWSVideoFrame(_ imageData: Data, to conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        wsVideoReady.remove(id)   // not ready until browser acks
        let wsFrame = buildWSBinaryFrame(imageData)
        conn.send(content: wsFrame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.queue.async {
                    self?.wsConnections.removeAll { $0 === conn }
                    self?.wsVideoReady.remove(id)
                }
                print("[MJPEGServer] WS video client dropped: \(error)")
            }
        })
    }

    nonisolated private func sendFrame(_ frame: Data, frameID: UInt64, to conn: NWConnection) {
        let connID = ObjectIdentifier(conn)
        busyClients.insert(connID)
        conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                self.busyClients.remove(connID)
                if let error {
                    print("[MJPEGServer] Client dropped: \(error)")
                    self.streamConnections.removeAll { $0 === conn }
                    self.onClientCountChanged?(self.streamConnections.count)
                } else if self.latestFrameID > frameID, let latest = self.latestFrame {
                    // A newer frame arrived while we were busy — send it now
                    self.sendFrame(latest, frameID: self.latestFrameID, to: conn)
                }
            }
        })
    }
}
