'use strict';
const $ = id => document.getElementById(id);
// Keep only the previous artwork in this tab, so every reload gets another.
const mascots = ['disk', 'tea', 'wave'];
let previous = null;
try { previous = sessionStorage.getItem('mayfly-mascot'); } catch {}
const choices = mascots.filter(name => name !== previous);
const mascot = choices[Math.floor(Math.random() * choices.length)];
$('corner-girl').src = `/mascot-${mascot}.png`;
try { sessionStorage.setItem('mayfly-mascot', mascot); } catch {}

const form = document.querySelector('form');
const status = $('status');
const file = $('file');
const drop = $('drop');
for (const event of ['dragenter', 'dragover']) drop.addEventListener(event, e => {e.preventDefault();drop.classList.add('over');});
for (const event of ['dragleave', 'drop']) drop.addEventListener(event, e => {e.preventDefault();drop.classList.remove('over');});
drop.addEventListener('drop', e => {if(e.dataTransfer.files.length !== 1){status.textContent='One file at a time, please.';return;}file.files=e.dataTransfer.files;});
form.addEventListener('submit', e => {
 e.preventDefault();
 if (!file.files.length || !file.files[0].size || file.files[0].size > 200*1024*1024) {status.textContent='Choose a nonempty file up to 200 MiB.';return;}
 $('send').disabled=true; $('result').hidden=true; $('progress').hidden=false; $('progress').value=0; status.textContent='Sending your file…';
 const xhr=new XMLHttpRequest();xhr.open('POST','/api/upload');xhr.timeout=600000;
 xhr.upload.onprogress=e=>{if(e.lengthComputable)$('progress').value=100*e.loaded/e.total;};
 const done=()=>{$('send').disabled=false;$('progress').hidden=true;};
 xhr.onload=()=>{done();if(xhr.status!==200){status.textContent=xhr.responseText||'Upload failed. Please try again.';return;}try{const data=JSON.parse(xhr.responseText);$('link').value=data.url;$('deletion').value=data.delete_url;$('expires').textContent='Expires '+new Date(data.expires).toLocaleString();$('result').hidden=false;$('delete').disabled=false;status.textContent='Your file has taken flight.';}catch{status.textContent='Unexpected server response.';}};
 xhr.onerror=()=>{done();status.textContent='Connection failed. Please try again.';};xhr.ontimeout=()=>{done();status.textContent='Upload timed out. Please try again.';};xhr.send(new FormData(form));
});
$('copy').addEventListener('click',async()=>{try{await navigator.clipboard.writeText($('link').value);status.textContent='Link copied.';}catch{$('link').select();status.textContent='Select and copy the link above.';}});
$('delete').addEventListener('click',async()=>{if(!confirm('Delete this file now? This cannot be undone.'))return;try{const response=await fetch($('deletion').value,{method:'DELETE'});if(!response.ok)throw Error();$('delete').disabled=true;status.textContent='File deleted. The download link no longer works.';}catch{status.textContent='Deletion failed. The file may already have expired.';}});
