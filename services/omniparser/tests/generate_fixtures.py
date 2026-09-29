"""Render synthetic static UI contract fixtures; annotations are hand-authored, not model predictions."""
from pathlib import Path
import json
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3] / "Tests/Fixtures/Perception"
ROOT.mkdir(parents=True, exist_ok=True)
FONT = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 20)
SMALL = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 16)


def scene(name, title, background, style):
    image = Image.new("RGB", (960, 640), background)
    draw = ImageDraw.Draw(image)
    detections = []
    def item(kind, box, text=None, description=None, interactive=False, fill=None):
        if fill:
            draw.rectangle(box, fill=fill, outline="#707780", width=1)
        if text:
            draw.text((box[0] + 7, box[1] + 6), text, font=SMALL if kind == "text" else FONT, fill="white" if style == "bios" else "#182332")
        detections.append(dict(type=kind, bbox=[box[0]/960, box[1]/640, box[2]/960, box[3]/640], text=text,
            description=description, interactive=interactive, confidence=0.99, metadata={"fixture": "hand-authored"}))
    if style == "bios":
        item("window", [4, 4, 956, 636], description="Firmware setup", fill="#142f87")
        item("text", [20, 20, 800, 55], title)
        item("tab", [30, 90, 180, 125], "Main", interactive=True, fill="#294fa9")
        item("tab", [200, 90, 350, 125], "Boot", interactive=True, fill="#294fa9")
        item("text", [30, 160, 450, 195], "System Memory: 65536 MB")
        item("text", [30, 220, 260, 252], "Boot Mode")
        item("dropdown", [310, 214, 590, 255], "UEFI", interactive=True, fill="#294fa9")
        item("text", [30, 530, 830, 565], "F10 Save and Exit    Esc Exit    Arrow keys Move")
    else:
        item("window", [10, 10, 950, 630], description=title, fill="#f7f8fa")
        item("toolbar", [10, 10, 950, 67], description="Window toolbar", fill="#e4e7ec")
        item("text", [300, 24, 720, 53], title)
        if style == "mac":
            for x, color in [(30,"#ed6a5e"),(55,"#f5bf4f"),(80,"#62c554")]:
                draw.ellipse((x,29,x+14,43),fill=color)
        if style == "browser":
            item("icon", [24, 76, 58, 112], description="back", interactive=True)
            draw.line([(48,82),(32,94),(48,106)],fill="#293345",width=3)
            item("textfield", [85, 76, 850, 116], "https://example.test/account", interactive=True, fill="white")
            item("tab", [30, 126, 205, 163], "Account", interactive=True, fill="#e4e7ec")
            item("link", [750, 138, 900, 175], "Help", interactive=True)
        top = 180 if style == "browser" else 100
        item("dialog" if style == "windows" else "card", [140, top, 810, 570], description="Account settings", fill="white")
        item("text", [180, top+20, 550, top+45], "Username")
        item("textfield", [180, top+55, 700, top+96], description="Username input field", interactive=True, fill="#fafbfc")
        item("checkbox", [180, top+120, 204, top+144], description="Remember me checkbox", interactive=True, fill="white")
        draw.line([(184,top+130),(190,top+137),(201,top+123)],fill="#295ed8",width=3)
        item("text", [216, top+117, 455, top+147], "Remember me")
        item("dropdown", [180, top+170, 510, top+210], "English", description="Language dropdown", interactive=True, fill="#f5f6f8")
        draw.polygon([(480,top+185),(496,top+185),(488,top+195)],fill="#293345")
        item("button", [180, top+238, 340, top+280], "Save", interactive=True, fill="#dde7ff")
        item("button", [370, top+238, 540, top+280], "Cancel", interactive=True, fill="#edf0f3")
        item("icon", [710, top+238, 750, top+280], description="settings gear", interactive=True)
        draw.ellipse((716,top+244,744,top+272),outline="#344155",width=5)
        draw.ellipse((724,top+252,736,top+264),fill="white",outline="#344155",width=2)
    image.save(ROOT / f"{name}.png")
    (ROOT / f"{name}.json").write_text(json.dumps(detections, indent=2))


scene("browser", "Browser - Account", "#d9e0eb", "browser")
scene("macos", "Account Preferences", "#c6d5dd", "mac")
scene("windows_dialog", "Windows - Settings", "#376a97", "windows")
scene("bios_console", "UEFI Firmware Setup Utility", "#142f87", "bios")
