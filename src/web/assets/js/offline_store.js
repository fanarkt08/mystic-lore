// IndexedDB of the offline lessons (docs/contracts/offline.md). One database per device,
// « mysticlore-offline », created only when a member downloads a lesson. Stores:
//   meta      { key: "member", id }        : the member the device's offline data belongs to
//   packages  { lesson_id, member_id, … }  : lesson copies (server-rendered HTML, never the answers)
//   queue     { key, member_id, … }        : answers and finished stories waiting for synchronization
//   reports   { key, lesson_id, … }        : results of the last synchronizations (what the server said)
// Every record carries its member; offline.js deletes everything as soon as another member is signed in.

export const NAME = "mysticlore-offline"
const VERSION = 1
const KEYS = { meta: "key", packages: "lesson_id", queue: "key", reports: "key" }
const STORES = Object.keys(KEYS)

let opening = null

export const supported = () =>
  typeof indexedDB !== "undefined" && "serviceWorker" in navigator && window.isSecureContext === true

// Whether the database exists, without creating it (nothing is stored for a member who never downloads).
export async function exists() {
  if (typeof indexedDB === "undefined") return false
  if (typeof indexedDB.databases !== "function") return true
  try {
    return (await indexedDB.databases()).some((db) => db.name === NAME)
  } catch (_error) {
    return true
  }
}

function open() {
  if (!opening) {
    opening = new Promise((resolve, reject) => {
      const request = indexedDB.open(NAME, VERSION)
      request.onupgradeneeded = () => {
        const db = request.result
        for (const store of STORES) {
          if (!db.objectStoreNames.contains(store)) db.createObjectStore(store, { keyPath: KEYS[store] })
        }
      }
      request.onsuccess = () => {
        const db = request.result
        // another tab deletes the database (logout): let it, and reopen next time
        db.onversionchange = () => {
          db.close()
          opening = null
        }
        db.onclose = () => (opening = null)
        resolve(db)
      }
      request.onerror = () => {
        opening = null
        reject(request.error)
      }
      request.onblocked = () => {
        opening = null
        reject(new Error("IndexedDB blocked"))
      }
    })
  }
  return opening
}

const done = (request) =>
  new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })

async function transaction(stores, mode, body) {
  const db = await open()
  const tx = db.transaction(stores, mode)
  const finished = new Promise((resolve, reject) => {
    tx.oncomplete = resolve
    tx.onerror = () => reject(tx.error)
    tx.onabort = () => reject(tx.error || new Error("IndexedDB transaction aborted"))
  })
  const value = await body(...stores.map((name) => tx.objectStore(name)))
  await finished
  return value
}

export const getAll = (store) => transaction([store], "readonly", (s) => done(s.getAll()))
export const get = (store, key) => transaction([store], "readonly", (s) => done(s.get(key)))
export const put = (store, value) => transaction([store], "readwrite", (s) => done(s.put(value)))
export const remove = (store, key) => transaction([store], "readwrite", (s) => done(s.delete(key)))

export const clearAll = () =>
  transaction(STORES, "readwrite", (...stores) => Promise.all(stores.map((s) => done(s.clear()))))

// Deletes the whole database (logout). Resolves once it is gone, or after `timeout` ms if another tab holds it.
export async function destroy(timeout = 2000) {
  if (opening) {
    try {
      ;(await opening).close()
    } catch (_error) {
      // not open
    }
    opening = null
  }
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, timeout)
    const request = indexedDB.deleteDatabase(NAME)
    request.onsuccess = request.onerror = () => {
      clearTimeout(timer)
      resolve()
    }
  })
}
