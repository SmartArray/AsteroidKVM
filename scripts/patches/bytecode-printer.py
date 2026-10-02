# AsteroidKVM layout typing bytecode overlay v1
# GLKVM extension: GPL-3.0-or-later; see GLKVM-LICENSE.
# Load the installed vendor module unchanged, then normalize EuroSign.
def _asteroid_load_vendor():
    from importlib.machinery import SourcelessFileLoader
    from pathlib import Path
    path = str(Path(__file__).with_suffix('.pyc'))
    exec(SourcelessFileLoader(__name__, path).get_code(__name__), globals())


_asteroid_load_vendor()
_asteroid_original_ch_to_keysym = _ch_to_keysym


def _ch_to_keysym(ch):
    return 0x20AC if ch == '€' else _asteroid_original_ch_to_keysym(ch)


if '_ch_to_keysym_fallback' in globals():
    _asteroid_original_fallback = _ch_to_keysym_fallback

    def _ch_to_keysym_fallback(cp):
        return 0x20AC if cp == 0x20AC else _asteroid_original_fallback(cp)
