import React from 'react';import{createRoot}from'react-dom/client';import'./styles.css';import'./public-info.css';import{App}from'./App';import{PublicInfoPage}from'./PublicInfoPage';
const path=window.location.pathname.replace(/\/$/,'')||'/';
const publicPage=path==='/datenschutz'||path==='/privacy'?<PublicInfoPage page="privacy"/>:path==='/support'?<PublicInfoPage page="support"/>:null;
createRoot(document.getElementById('root')!).render(<React.StrictMode>{publicPage??<App/>}</React.StrictMode>);if('serviceWorker'in navigator)window.addEventListener('load',()=>navigator.serviceWorker.register('/sw.js').catch(()=>{}))
