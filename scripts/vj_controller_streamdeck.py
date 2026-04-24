#!/usr/bin/env python3
"""
Nuclear Winter VJ Controller
Handles mutually exclusive VJ selections for Front and Back rooms
Controls OBS via WebSocket
Uses Stream Deck hardware directly (no hotkeys needed)
"""

import os
import time
import threading
from obswebsocket import obsws, requests
from StreamDeck.DeviceManager import DeviceManager
from StreamDeck.ImageHelpers import PILHelper
from PIL import Image, ImageDraw, ImageFont

# ============================================================================
# CONFIGURATION - EDIT THESE VALUES TO MATCH YOUR SETUP
# ============================================================================

OBS_HOST = "localhost"
OBS_PORT = 4455
OBS_PASSWORD = "your_password_here"  # Change this to your OBS WebSocket password

# Scene names in OBS
FRONT_ROOM_SCENE = "Front Room"  # Change to your actual scene name
BACK_ROOM_SCENE = "Back Room"    # Change to your actual scene name

# OBS group containing Front Room VJ video sources
# Add/remove/rename sources inside this group in OBS, then press RELOAD
VJ_TITLES_GROUP = "VJ Titles"

# Stream Deck button layout:  0  1  2  3  [4=RELOAD]
#                             5  6  7  8  9
#                            10 11 12 13 14
FRONT_ROOM_BUTTON_SLOTS = [0, 1, 2, 3]  # buttons assigned to VJs in order
BACK_ROOM_BUTTON_SLOTS  = [5, 6, 7, 8]  # reserved for back room (future)
RELOAD_BUTTON = 4                        # press to reload VJ list from OBS

LOOP_DURATION = 120  # seconds (2 minutes)

# ============================================================================
# VJ CONTROLLER CLASS
# ============================================================================

class VJController:
    def __init__(self):
        self.ws = None
        self.deck = None
        self.front_active = None  # Currently active VJ in front room
        self.back_active = None   # Currently active VJ in back room
        self.front_loop_thread = None
        self.back_loop_thread = None
        self.running = True
        self.front_room_sources = {}  # {source_name: source_name} — populated from OBS
        self.front_room_buttons = {}  # {button_index: source_name} — populated from OBS
        self.back_room_sources  = {}
        self.back_room_buttons  = {}
        
    def connect_obs(self):
        """Connect to OBS WebSocket"""
        try:
            self.ws = obsws(OBS_HOST, OBS_PORT, OBS_PASSWORD)
            self.ws.connect()
            print(f"✓ Connected to OBS at {OBS_HOST}:{OBS_PORT}")
            return True
        except Exception as e:
            print(f"✗ Failed to connect to OBS: {e}")
            print("\nMake sure:")
            print("1. OBS is running")
            print("2. WebSocket server is enabled (Tools → WebSocket Server Settings)")
            print("3. Password in script matches OBS settings")
            return False
    
    def _label_from_source(self, source_name):
        """Derive a display label from the media file path, falling back to the source name."""
        try:
            settings_response = self.ws.call(requests.GetInputSettings(inputName=source_name))
            try:
                settings = settings_response.getInputSettings()
            except AttributeError:
                settings = settings_response.datain.get('inputSettings', {})

            file_path = settings.get('local_file', '')
            if file_path:
                label = os.path.splitext(os.path.basename(file_path))[0]
                # Strip trailing duration/variant suffix e.g. " - 15s", " - Loop"
                if ' - ' in label:
                    label = label.rsplit(' - ', 1)[0]
                return label
        except Exception:
            pass
        return source_name  # fallback: use OBS source name as-is

    def discover_vj_sources(self):
        """Query OBS for sources in VJ_TITLES_GROUP and map them to buttons in order."""
        try:
            response = self.ws.call(requests.GetSceneItemList(sceneName=VJ_TITLES_GROUP))
            raw = getattr(response, 'datain', {})
            items = raw.get('sceneItems', [])

            self.front_room_sources = {}
            self.front_room_buttons = {}

            for i, item in enumerate(items[:len(FRONT_ROOM_BUTTON_SLOTS)]):
                source_name = item['sourceName']
                label = self._label_from_source(source_name)
                self.front_room_sources[label] = source_name
                self.front_room_buttons[FRONT_ROOM_BUTTON_SLOTS[i]] = label

            print(f"✓ Loaded {len(self.front_room_buttons)} VJ(s) from OBS group '{VJ_TITLES_GROUP}':")
            for btn, label in self.front_room_buttons.items():
                source = self.front_room_sources[label]
                print(f"  Button {btn}: {label!r}  ←  OBS source '{source}'")

            if self.deck:
                self.update_all_buttons()

        except Exception as e:
            print(f"✗ Failed to load VJ sources from OBS: {e}")

    def disconnect_obs(self):
        """Disconnect from OBS"""
        if self.ws:
            self.ws.disconnect()
            print("Disconnected from OBS")
    
    def connect_streamdeck(self):
        """Connect to Stream Deck"""
        try:
            streamdecks = DeviceManager().enumerate()
            
            if not streamdecks:
                print("✗ No Stream Deck found!")
                print("Make sure your Stream Deck is connected.")
                return False
            
            self.deck = streamdecks[0]
            self.deck.open()
            self.deck.reset()
            
            print(f"✓ Connected to Stream Deck: {self.deck.deck_type()}")
            print(f"  Firmware: {self.deck.get_firmware_version()}")
            print(f"  Buttons: {self.deck.key_count()}")
            
            # Set up button press handler
            self.deck.set_key_callback(self.button_callback)
            
            # Initialize button images
            self.update_all_buttons()
            
            return True
            
        except Exception as e:
            print(f"✗ Failed to connect to Stream Deck: {e}")
            return False
    
    def disconnect_streamdeck(self):
        """Disconnect from Stream Deck"""
        if self.deck:
            self.deck.reset()
            self.deck.close()
            print("Disconnected from Stream Deck")
    
    def create_button_image(self, text, active=False):
        """Create an image for a Stream Deck button"""
        # Get button image dimensions
        image = PILHelper.create_image(self.deck)
        draw = ImageDraw.Draw(image)
        
        # Choose colors based on active state
        if active:
            bg_color = (255, 0, 0)  # Red background when active
            text_color = (255, 255, 255)
        else:
            bg_color = (0, 0, 0)  # Black background when inactive
            text_color = (200, 200, 200)
        
        # Draw background
        draw.rectangle([(0, 0), image.size], fill=bg_color)
        
        # Draw text
        try:
            font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 14)
        except:
            font = ImageFont.load_default()
        
        # Word wrap text
        words = text.split()
        lines = []
        current_line = []
        
        for word in words:
            test_line = ' '.join(current_line + [word])
            bbox = draw.textbbox((0, 0), test_line, font=font)
            if bbox[2] - bbox[0] <= image.width - 10:
                current_line.append(word)
            else:
                if current_line:
                    lines.append(' '.join(current_line))
                current_line = [word]
        
        if current_line:
            lines.append(' '.join(current_line))
        
        # Draw text centered
        y_offset = (image.height - len(lines) * 20) // 2
        for line in lines:
            bbox = draw.textbbox((0, 0), line, font=font)
            text_width = bbox[2] - bbox[0]
            x = (image.width - text_width) // 2
            draw.text((x, y_offset), line, font=font, fill=text_color)
            y_offset += 20
        
        return PILHelper.to_native_format(self.deck, image)
    
    def update_button(self, button_index, vj_name, active=False):
        """Update a single button's image"""
        if self.deck:
            image = self.create_button_image(vj_name, active)
            self.deck.set_key_image(button_index, image)
    
    def update_all_buttons(self):
        """Update all button images"""
        for button_index, vj_name in self.front_room_buttons.items():
            active = (self.front_active == vj_name)
            self.update_button(button_index, vj_name, active)

        for button_index, vj_name in self.back_room_buttons.items():
            active = (self.back_active == vj_name)
            self.update_button(button_index, vj_name, active)

        # RELOAD button — always shown
        self.update_button(RELOAD_BUTTON, "RELOAD", active=False)
    
    def button_callback(self, deck, key, state):
        """Handle Stream Deck button presses"""
        if not state:
            return

        if key == RELOAD_BUTTON:
            print("\n[RELOAD] Refreshing VJ list from OBS...")
            self.discover_vj_sources()
        elif key in self.front_room_buttons:
            vj_name = self.front_room_buttons[key]
            self.toggle_vj("front", vj_name)
            self.update_all_buttons()
        elif key in self.back_room_buttons:
            vj_name = self.back_room_buttons[key]
            self.toggle_vj("back", vj_name)
            self.update_all_buttons()
    
    def get_scene_item_id(self, scene_name, source_name):
        """Get the scene item ID for a source in a scene"""
        try:
            response = self.ws.call(requests.GetSceneItemId(
                sceneName=scene_name,
                sourceName=source_name
            ))
            return response.getSceneItemId()
        except Exception as e:
            print(f"Warning: Could not get scene item ID for {source_name} in {scene_name}: {e}")
            return None
    
    def set_source_visibility(self, scene_name, source_name, visible):
        """Show or hide a source in a scene"""
        try:
            item_id = self.get_scene_item_id(scene_name, source_name)
            if item_id is not None:
                self.ws.call(requests.SetSceneItemEnabled(
                    sceneName=scene_name,
                    sceneItemId=item_id,
                    sceneItemEnabled=visible
                ))
                status = "shown" if visible else "hidden"
                print(f"  → {source_name} {status}")
        except Exception as e:
            print(f"  ✗ Error setting visibility for {source_name}: {e}")
    
    def control_media(self, source_name, action):
        """Control media source (play, pause, restart, stop)"""
        try:
            if action == "restart":
                self.ws.call(requests.TriggerMediaInputAction(
                    inputName=source_name,
                    mediaAction="OBS_WEBSOCKET_MEDIA_INPUT_ACTION_RESTART"
                ))
            elif action == "stop":
                self.ws.call(requests.TriggerMediaInputAction(
                    inputName=source_name,
                    mediaAction="OBS_WEBSOCKET_MEDIA_INPUT_ACTION_STOP"
                ))
            elif action == "play":
                self.ws.call(requests.TriggerMediaInputAction(
                    inputName=source_name,
                    mediaAction="OBS_WEBSOCKET_MEDIA_INPUT_ACTION_PLAY"
                ))
        except Exception as e:
            print(f"  ✗ Error controlling media {source_name}: {e}")
    
    def hide_all_sources(self, room):
        """Hide all VJ sources in a room"""
        scene = VJ_TITLES_GROUP
        if room == "front":
            sources = self.front_room_sources
        else:
            sources = self.back_room_sources

        for vj_name, source_name in sources.items():
            self.set_source_visibility(scene, source_name, False)
            self.control_media(source_name, "stop")
    
    def loop_vj(self, room, vj_name):
        """Loop a VJ video every 2 minutes"""
        if room == "front":
            scene = FRONT_ROOM_SCENE
            source_name = self.front_room_sources[vj_name]
        else:
            scene = BACK_ROOM_SCENE
            source_name = self.back_room_sources[vj_name]
        
        print(f"  ⟳ Starting loop for {vj_name} in {room} room")
        
        while self.running:
            # Check if this VJ is still the active one
            if room == "front" and self.front_active != vj_name:
                break
            if room == "back" and self.back_active != vj_name:
                break
            
            # Play/restart the video
            self.control_media(source_name, "restart")
            
            # Wait for loop duration
            time.sleep(LOOP_DURATION)
        
        print(f"  ⟳ Stopped loop for {vj_name} in {room} room")
    
    def toggle_vj(self, room, vj_name):
        """Toggle a VJ on/off with mutual exclusivity"""
        if room == "front":
            current = self.front_active
            scene = FRONT_ROOM_SCENE
            source_name = self.front_room_sources[vj_name]
        else:
            current = self.back_active
            scene = BACK_ROOM_SCENE
            source_name = self.back_room_sources[vj_name]
        
        print(f"\n[{room.upper()} ROOM] Button pressed: {vj_name}")
        
        if current == vj_name:
            # Toggle OFF - deactivate this VJ
            print(f"  ⊗ Deactivating {vj_name}")
            
            if room == "front":
                self.front_active = None
            else:
                self.back_active = None
            
            self.set_source_visibility(scene, source_name, False)
            self.control_media(source_name, "stop")
            
        else:
            # Toggle ON - activate this VJ and deactivate others
            if current:
                print(f"  ⊗ Deactivating {current}")
            print(f"  ⊕ Activating {vj_name}")
            
            # Hide all sources first
            self.hide_all_sources(room)
            
            # Update active VJ
            if room == "front":
                self.front_active = vj_name
            else:
                self.back_active = vj_name
            
            # Show and play the selected VJ
            self.set_source_visibility(scene, source_name, True)
            
            # Start the loop in a background thread
            if room == "front":
                if self.front_loop_thread and self.front_loop_thread.is_alive():
                    self.front_loop_thread.join(timeout=0.5)
                self.front_loop_thread = threading.Thread(
                    target=self.loop_vj, 
                    args=(room, vj_name),
                    daemon=True
                )
                self.front_loop_thread.start()
            else:
                if self.back_loop_thread and self.back_loop_thread.is_alive():
                    self.back_loop_thread.join(timeout=0.5)
                self.back_loop_thread = threading.Thread(
                    target=self.loop_vj, 
                    args=(room, vj_name),
                    daemon=True
                )
                self.back_loop_thread.start()

# ============================================================================
# MAIN
# ============================================================================

def main():
    print("=" * 60)
    print("Nuclear Winter VJ Controller")
    print("=" * 60)
    
    controller = VJController()
    
    if not controller.connect_obs():
        return

    controller.discover_vj_sources()

    if not controller.connect_streamdeck():
        controller.disconnect_obs()
        return

    print("\n✓ VJ Controller is running!")
    print(f"  Button {RELOAD_BUTTON}: RELOAD — press to refresh VJ list from OBS")
    print("\nButtons turn RED when active")
    print("\nPress Ctrl+C to stop\n")
    
    try:
        # Keep the script running
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n\nStopping VJ Controller...")
        controller.running = False
        controller.disconnect_streamdeck()
        controller.disconnect_obs()
        print("✓ Shutdown complete")

if __name__ == "__main__":
    main()
