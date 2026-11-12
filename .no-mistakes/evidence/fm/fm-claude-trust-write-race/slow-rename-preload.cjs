const fs=require("node:fs");const r=fs.renameSync;fs.renameSync=(a,b)=>{if(String(b).endsWith(".claude.json"))Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,300);return r(a,b)};
