import type {Generation,ModelInfo,PromptTemplate,ProviderConfiguration} from '../types'
const TOKEN='cdance-token',SESSION='cdance-session'
export const auth={get:()=>localStorage.getItem(TOKEN),session:()=>localStorage.getItem(SESSION),set:(access:string,session:string)=>{localStorage.setItem(TOKEN,access);localStorage.setItem(SESSION,session)},clear:()=>{localStorage.removeItem(TOKEN);localStorage.removeItem(SESSION)}}
export class ApiError extends Error{constructor(public status:number,message:string,public code='api_error'){super(message)}}
export async function api<T>(path:string,init:RequestInit={},retry=true):Promise<T>{
 const headers=new Headers(init.headers);const token=auth.get();if(token)headers.set('Authorization',`Bearer ${token}`);if(init.body&&!(init.body instanceof FormData))headers.set('Content-Type','application/json')
 const response=await fetch(`/api/v1${path}`,{...init,headers});if(response.status===401&&retry&&auth.session()){const refreshed=await fetch('/api/v1/auth/refresh',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({session_token:auth.session()})});if(refreshed.ok){const tokens=await refreshed.json();auth.set(tokens.access_token,tokens.session_token);return api<T>(path,init,false)}}if(response.status===204)return undefined as T
 const body=await response.json().catch(()=>({}));if(!response.ok)throw new ApiError(response.status,body.error?.message||'Die Anfrage ist fehlgeschlagen.',body.error?.code)
 return body as T
}
export const endpoints={
 login:(username:string,password:string)=>api<{access_token:string;session_token:string}>('/auth/login',{method:'POST',body:JSON.stringify({username,password})}),
 models:()=>api<{default_model:string;models:ModelInfo[]}>('/models'),
 prompts:()=>api<PromptTemplate[]>('/prompts'),
 history:()=>api<{items:Generation[];total:number}>('/generations?limit=100'),
 generation:(id:string)=>api<Generation>(`/generations/${id}`),
 regenerate:(id:string)=>api<Generation>(`/generations/${id}/regenerate`,{method:'POST'}),
 variation:(id:string)=>api<Generation>(`/generations/${id}/variation`,{method:'POST'}),
 deleteGeneration:(id:string)=>api<{deleted:boolean;files_deleted:number}>(`/generations/${id}`,{method:'DELETE'}),
 provider:()=>api<ProviderConfiguration>('/provider/config'),
 configureProvider:(apiKey:string)=>api<ProviderConfiguration>('/provider/config',{method:'PUT',body:JSON.stringify({api_key:apiKey})}),
 removeProvider:()=>api<ProviderConfiguration>('/provider/config',{method:'DELETE'}),
 savePrompt:(p:Partial<PromptTemplate>,id?:string)=>api<PromptTemplate>(id?`/prompts/${id}`:'/prompts',{method:id?'PUT':'POST',body:JSON.stringify(p)}),
 copyPrompt:(id:string)=>api<PromptTemplate>(`/prompts/${id}/copy`,{method:'POST'}),
 deletePrompt:(id:string)=>api<void>(`/prompts/${id}`,{method:'DELETE'}),
}
