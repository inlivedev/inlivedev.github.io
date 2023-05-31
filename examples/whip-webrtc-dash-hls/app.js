import { WHIPClient } from "./whip.js"

const API_KEY = '<api-key-here>'
const API_HOST = `https://api.inlive.app`

async function createStream(){
    const resp = await fetch(`${API_HOST}/v1/streams/create`,{
        method: 'POST',
        mode: "cors",
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${API_KEY}`
        },
        body: JSON.stringify({
            name: 'My live stream',
        })
    })

    if (resp.ok){
        const respJSON = await resp.json()
        return respJSON.data
    } else {
        throw new Error(resp.statusText)
    }
}

async function WHIP(stream, mediaStream){
    const pc = new RTCPeerConnection();

    //Send all tracks
    for (const track of mediaStream.getTracks()) {
        //You could add simulcast too here
        pc.addTrack(track);
    }

    //Create whip client
    const whip = new WHIPClient();
    const url  = `${API_HOST}/v1/streams/${stream.id}/whip`
    await whip.publish(pc, url, API_KEY);
}

async function startStream(stream, mediaStream){
    const resp = await fetch(`${API_HOST}/v1/streams/${stream.id}/start`, {
        method: 'POST',
        mode: "cors",
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${API_KEY}`
        }
    })

    if (resp.status === 200){
        const respJSON = await resp.json()
        return respJSON.data
    } else {
        throw new Error(resp.statusText)
    }
}

document.addEventListener('DOMContentLoaded', async () => {
    const mediaStream = await navigator.mediaDevices.getUserMedia({
        video: true,
        audio: true
    })
    const video = document.getElementById('video')
    video.srcObject = mediaStream
    const button = document.querySelector('button')
    
    button.addEventListener('click', async () => {
        const stream = await createStream()
        await WHIP(stream, mediaStream)
        const manifest = await startStream(stream)
        const a = document.createElement('a')
        a.href = `https://players.akamai.com/players/dashjs?streamUrl=${manifest.dash}`
        a.innerText = 'Watch live stream'
        a.target = '_blank'
        document.body.appendChild(a)
    })
})