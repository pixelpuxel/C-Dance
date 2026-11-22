import { useEffect, useRef, useState } from 'react';
import type { Generation } from '../types';

export function ResultView({generation,onClose,onDelete,onReuseSetup,onRegenerate,onVariation,onEdit,onReference}:{generation:Generation;onClose:()=>void;onDelete:()=>void;onReuseSetup:()=>void;onRegenerate:()=>void;onVariation:()=>void;onEdit:()=>void;onReference:()=>void}) {
  const [prompt,setPrompt]=useState(false),[details,setDetails]=useState(false),openedAt=useRef(performance.now());
  useEffect(()=>{const previous=document.body.style.overflow;document.body.style.overflow='hidden';return()=>{document.body.style.overflow=previous}},[]);
  const media=generation.images.find(item=>item.role==='result')||generation.images[0];
  if(!media)return null;
  const close=()=>{if(performance.now()-openedAt.current>=800)onClose()};
  const share=async()=>{
    const blob=await fetch(media.download_url).then(response=>response.blob());
    const extension=media.mime_type==='video/quicktime'?'mov':'mp4';
    const file=new File([blob],`cdance-${generation.id}.${extension}`,{type:blob.type});
    if(navigator.share&&navigator.canShare?.({files:[file]}))await navigator.share({files:[file],title:'C-Dance Film'});else window.open(media.download_url,'_blank');
  };
  return <div className="modal" role="dialog" aria-modal="true" aria-label="Ergebnisfilm"><div className="result panel" onPointerDown={event=>event.stopPropagation()} onClick={event=>event.stopPropagation()}>
    <header><div><h2>Ergebnis</h2><small>{new Date(generation.created_at).toLocaleString('de-DE')}</small></div><button onClick={close}>Schließen</button></header>
    <video className="result-image" src={media.download_url} controls playsInline preload="metadata" aria-label={generation.final_prompt}/>
    <div className="result-actions"><button className="primary" onClick={onReuseSetup}>Setup weiterverwenden</button><button onClick={onEdit}>Weiterbearbeiten</button><button onClick={onRegenerate}>Wiederholen</button><button onClick={onVariation}>Variation</button><a className="button" href={media.download_url} download>Download</a><button onClick={share}>Teilen</button><button onClick={onReference}>Als Referenz</button><button onClick={onDelete}>Dauerhaft löschen</button></div>
    <div className="details"><button onClick={()=>setPrompt(!prompt)}>Prompt {prompt?'ausblenden':'anzeigen'}</button><button onClick={()=>setDetails(!details)}>Einstellungen {details?'ausblenden':'anzeigen'}</button>{prompt&&<textarea readOnly rows={6} value={generation.final_prompt}/>} {details&&<dl><dt>Modell</dt><dd>{generation.model}</dd><dt>Format</dt><dd>{generation.aspect_ratio}</dd><dt>Auflösung</dt><dd>{generation.resolution}</dd><dt>Dauer</dt><dd>{String(generation.parameters.duration??'–')} s</dd><dt>Referenzen</dt><dd>{generation.references.length}</dd></dl>}</div>
  </div></div>;
}
