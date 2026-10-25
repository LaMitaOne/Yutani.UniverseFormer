# Yutani.UniverseFormer
A standalone 3D universe designer built with Raylib and Delphi. Design entire galaxies of star systems, place individual planets, and sculpt the cosmos in real-time. The new Yutani doesn't stop at terraforming — we create everything, from individual planets to entire universes. 
          
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/Yutani.UniverseFormer)    
        
 <img width="1920" height="1080" alt="ryzen4500u" src="https://github.com/user-attachments/assets/a80d0d57-b170-4fa6-a9c2-8977ab00b768" />
        
## Features     
     
- **12 Placement Templates**: 5 individual planet types (Rocky, Earth, Mars, Gas Giant, Ice), 5 complete star system types (Sol-Like, Random, Binary, Dwarf, Empty Sun), a Random Universe generator, and Clear.     
- **Smart Placement**: Always spawns exactly where you click. If other systems are in the way, they are smoothly pushed aside in full 3D (X, Y, and Z axes).     
- **Individual Planet Editing**: Click near a sun with a planet brush, and the planet will automatically join that system's orbit and circle the sun like the others.     
- **True 3D Distribution**: The "Random Universe" generator distributes systems across a large 3D volume, not just a flat 2D plane.     
- **Interactive Editing**: Select any system to drag it around the universe with your mouse, or use the keyboard to fine-tune its height.     
- **Massive Scale**: Tested with 480+ star systems simultaneously at 57 FPS on a laptop Ryzen 4500U. Desktop GPUs can handle thousands.     
- **Save/Load**: Save or load universe to/from SQLite db.   
     
## Controls     
     
 **Middle Mouse Button** | Orbit camera |
 **Mouse Wheel** | Zoom in/out |
 **WASD / Arrow Keys** | Pan camera target |
 **Left Mouse Button** | Select system / Place template / Drag selected system |
 **+ / - Keys** (next to Backspace) | Move selected system up/down (Y axis) |
 **DEL** | Delete selected system |
 **ESC** | Deselect / Cancel active brush |
     
## Technical Implementation     
     
- **VBO Rendering**: All planets and suns are rendered using a single pre-uploaded sphere mesh (Vertex Buffer Object) via Raylib's `DrawModel`. The mesh is stored in GPU memory and re-used for every object, tinted only by a color parameter. This avoids the CPU overhead of immediate-mode vertex pushing (`rlVertex3f`) and achieves near-instanced rendering performance.     
- **Batched Lines**: Grid lines and orbit rings are rendered in a single `rlBegin(RL_LINES)` batch to minimize draw calls.     
- **Custom Far Plane**: Raylib's default camera far plane is 1000 units. The renderer overrides the projection matrix after `BeginMode3D` to extend this to 10,000 units, allowing the entire universe to be visible from afar.     
- **Smooth Transforms**: Systems use a dual-position system (`Position` and `TargetPosition`). When pushed aside by a new spawn, only the `TargetPosition` is updated. Every frame, the `Position` lerps toward the target, creating a smooth glide animation.     
- **Strict 3D Separation**: The smart placement logic enforces strict minimum distances on both the XZ plane (based on orbital bounds) and the Y axis (based on sun size) to guarantee systems never visually overlap or crash into each other.     
- **No Textures**: To maximize performance and minimize startup time, no textures are generated. All objects are solid-colored, lit by the default material.     
     
Part of Yutani https://github.com/LaMitaOne/Yutani-Building-better-worlds     
         
<img width="2560" height="1440" alt="rtx2060sryzen5800" src="https://github.com/user-attachments/assets/78e4497b-b265-4e92-b419-ca29cdf5044e" /> 

