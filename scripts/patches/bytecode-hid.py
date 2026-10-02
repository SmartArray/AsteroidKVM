# AsteroidKVM layout typing bytecode overlay v1
# Adapted from GLKVM PR #158, GPL-3.0-or-later; see GLKVM-LICENSE.
# Preserve the installed vendor implementation and add the mapped-text API.
def _asteroid_load_vendor():
    from importlib.machinery import SourcelessFileLoader
    from pathlib import Path
    path = str(Path(__file__).with_suffix('.pyc'))
    exec(SourcelessFileLoader(__name__, path).get_code(__name__), globals())


_asteroid_load_vendor()
_asteroid_original_get_keymaps = HidApi.get_keymaps


async def _asteroid_get_keymaps(self):
    state = await _asteroid_original_get_keymaps(self)
    return dict(state, mapped_text=True)


@exposed_ws('mapped_text')
async def _asteroid_mapped_text(self, ws, event):
    try:
        text = event['text']
        if not isinstance(text, str) or len(text) != 1 or not text.isprintable():
            raise ValueError('Expected one printable character')
        symmap = self._HidApi__ensure_symmap(event.get('keymap', self._HidApi__default_keymap_name))
        events = list(text_to_evdev_keys(text, symmap))
    except Exception:
        await ws.send_event('mapped_text_result', {'mapped': False, 'reason': 'invalid'})
        return
    if events:
        await self._HidApi__hid.send_key_events(events, no_ignore_keys=True, slow=False)
    await ws.send_event('mapped_text_result', {'mapped': bool(events), 'text': text})


HidApi.get_keymaps = _asteroid_get_keymaps
HidApi._HidApi__ws_mapped_text_handler = _asteroid_mapped_text
