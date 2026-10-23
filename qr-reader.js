/* ORSHAP WMS QR decoder fallback. BarcodeDetector remains preferred where supported. */
(function(){
  'use strict';
  function load(src){return new Promise((resolve,reject)=>{const s=document.createElement('script');s.src=src;s.async=true;s.crossOrigin='anonymous';s.onload=()=>window.jsQR?resolve(window.jsQR):reject(new Error('jsQR global missing'));s.onerror=()=>{s.remove();reject(new Error('QR decoder CDN failed'))};document.head.appendChild(s)})}
  window.orshapQrReaderReady=(async()=>{
    if(window.jsQR)return window.jsQR;
    try{return await load('https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.min.js')}
    catch(_){return await load('https://unpkg.com/jsqr@1.4.0/dist/jsQR.js')}
  })();
  window.orshapQrReaderReady.catch(()=>{});
})();
