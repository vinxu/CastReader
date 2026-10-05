import { contextBridge, ipcRenderer } from "electron";
import type { DesktopBridge } from "../core/bridge";

const bridge: DesktopBridge = {
  bootstrap: () => ipcRenderer.invoke("cr:bootstrap"),
  sendCode: (email, region) =>
    ipcRenderer.invoke("cr:sendCode", { email, region }),
  signIn: (email, otp, region) =>
    ipcRenderer.invoke("cr:signIn", { email, otp, region }),
  signOut: () => ipcRenderer.invoke("cr:signOut"),
  entitlement: () => ipcRenderer.invoke("cr:entitlement"),
  importFile: () => ipcRenderer.invoke("cr:importFile"),
  saveDocument: (document) => ipcRenderer.invoke("cr:saveDocument", document),
  deleteDocument: (id) => ipcRenderer.invoke("cr:deleteDocument", id),
  savePreferences: (value) => ipcRenderer.invoke("cr:savePreferences", value),
  saveCheckpoint: (value) => ipcRenderer.invoke("cr:saveCheckpoint", value),
  speak: (input) => ipcRenderer.invoke("cr:speak", input),
  cancelSpeech: () => ipcRenderer.invoke("cr:cancelSpeech"),
  track: (input) => ipcRenderer.invoke("cr:track", input),
};
contextBridge.exposeInMainWorld("castreader", bridge);
