# MiOS Roadmap: From Here to the Dynabook

## Where We Are (v0.1 — 18 March 2026)

- [x] Standalone GUI shell (Zig + Raylib + QuickJS)
- [x] Terminal emulator with ANSI, scrollback, resize
- [x] Unified window manager (drag, resize, z-order, chrome)
- [x] Display windows with 2D/3D rendering from JS
- [x] Microkernel bridge (wire protocol, TCP mount, hello handshake)
- [x] Bidirectional remote terminal (input → shell, output → terminal)
- [x] Actor registration (mios-console, mios-display on remote nodes)
- [x] Remote display forwarding (FILL, TEXT, CLEAR → MiOS display windows)
- [x] Performance overlay with QuickJS memory instrumentation
- [x] All JS tutorials working (starfield, meshes, etc.)

---

## Phase 1: Solid Foundation (weeks)

**Unify all windows into the window manager**
- Display windows (gfx API) join the same z-order as terminals
- One hit-test, one drag system, one render pass
- Close button on display windows kills the owning program

**Full display protocol forwarding**
- MSG_DISPLAY_DRAW (pixel blits) — RGB565 → texture upload
- MSG_DISPLAY_TEXT_ATTR (per-cell colored text) — console rendering
- MSG_DISPLAY_BRIGHTNESS, DISPLAY_POWER — map to window opacity/visibility
- Begin/end frame batching (don't create a new frame per command)

**Terminal fixes**
- ANSI rendering bugs (strikethrough bleed, OSC sequences)
- Proper SGR reset handling
- Hyperlink support (OSC 8)

**Multi-node mounts**
- Mount multiple kernels simultaneously, each with own terminal + display
- `mount <host>:<port>` as a shell built-in command
- Unmount / disconnect handling
- Node status indicator in window chrome

**Microkernel repo cleanup**
- Fix .gitignore (node_modules committed)
- Push the console stdout pipe + MSG_CONSOLE_SUBSCRIBE changes

---

## Phase 2: The Scripting Environment (weeks)

**JS ↔ Actor bridge improvements**
- `actor.lookup(path)` — send MSG_NS_LOOKUP, wait for reply
- `actor.subscribe(path, type)` — register for events
- `actor.on(type, callback)` — event-driven message handling
- Automatic reconnect on disconnect

**Remote actor access from JS**
- `actor.send("/node/esp32/hardware/gpio", MSG_GPIO_WRITE, payload)`
- Query remote capabilities: `actor.caps("esp32-amoled")`
- GPIO, I2C, PWM, LED control from the desktop

**WASM actor spawning from MiOS**
- Upload .wasm to remote node via MSG_SPAWN_REQUEST
- Hot reload via MSG_RELOAD_REQUEST
- Monitor actor lifecycle (MSG_CHILD_EXIT)

**Editor improvements**
- edit.js with syntax highlighting
- Save/load from remote KV store
- Edit scripts on remote nodes

---

## Phase 3: Behaviors & Composition (months)

**Behavior system**
- Behaviors as actors that attach to objects
- `rotate`, `colorpulse`, `orbit`, `physics`, `decay`, `proximity`
- Composable: attach multiple behaviors, zero conflicts
- Network-transparent: behavior actor can run on any node

**Scene graph**
- Retained-mode scene with actor-per-object
- Scene updates via messages (position, color, visibility)
- Compositor actor manages dirty regions, render order

**Live documents**
- Document = array of actor elements
- `Heading`, `Chart`, `Scene3D`, `Text`, `Table`
- Elements subscribe to data actors
- Data changes propagate automatically
- The document IS the program

---

## Phase 4: Hardware Integration (months)

**ESP32 as first-class display target**
- Mount ESP32 nodes from MiOS
- ESP32 display output appears as MiOS window
- MiOS display commands render on ESP32 AMOLED/LCD
- Touch events from ESP32 → MiOS input

**Sensor & actuator dashboard**
- GPIO state visualization
- I2C device scanner
- MIDI monitor/sequencer control from desktop
- LED strip control with live preview

**Multi-display compositor**
- One scene, multiple displays
- ESP32 AMOLED shows dashboard, desktop shows full viz
- Same actors, different views

---

## Phase 5: Social Magnetics Substrate (ongoing)

**Distributed by default**
- Any actor can live on any node
- Cloudflare edge integration (KV, D1, AI inference)
- WebSocket bridge for browser clients
- Phone as a node (React Native or WebView + actor bridge)

**Social Magnetics primitives**
- Opportunity actor (location, skills, requirements)
- Matching actor (proximity + embedding similarity)
- Route actor (connects opportunity → person)
- All message-passing, all composable

**Community features**
- Shared scenes (multiple users viewing/editing same actor graph)
- Real-time collaboration via actor subscription
- Permission model via capability actors

---

## The Destination

```
MiOS Desktop
├── Terminal (local shell)
├── Terminal (esp32-amoled) ← remote shell over WiFi
├── Terminal (cloud-worker) ← remote shell over WebSocket
├── Display (3D scene) ← meshes rendered by behavior actors
├── Display (dashboard) ← subscribed to sensor actors
├── Display (social-map) ← Social Magnetics visualization
└── Document (live report) ← actors updating charts in real-time
```

Every window is an actor. Every connection is a mount.
Every document is a program. Every device is a node.

Drop-dead simple for the common case.
Full power for the edge cases.
Certified enshittification-free.

It's actors all the way down.
