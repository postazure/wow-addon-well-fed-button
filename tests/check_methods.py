"""Fails if the addon calls a :Method( that Forever's widget API docs don't list,
unless it is a known non-widget method (Blizzard Lua mixins, our own methods).
Catches things like SetObeyStepMinMax, which doesn't exist on Forever."""
import glob
import os
import re
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
documented = {
    line.strip() for line in open(os.path.join(root, 'tests', 'forever_widget_methods.txt'), encoding='utf-8')
    if line.strip() and not line.startswith('#')
}

# Verified another way, not widget methods in the docs:
known = {
    # GameTooltip methods (used by other Forever addons).
    'AddLine', 'AddDoubleLine', 'SetOwner', 'GetOwner', 'SetItemByID',
    # BackdropTemplateMixin (Lua).
    'SetBackdrop', 'SetBackdropColor', 'SetBackdropBorderColor',
    # Menu / MenuUtil description objects (Lua), as other Forever addons use them.
    'GetOpenMenu', 'CreateTitle', 'CreateRadio', 'CreateCheckbox', 'CreateButton', 'CreateDivider',
    # Our own method on the glow frame.
    'SetGlowColor',
}

bad = []
for path in sorted(glob.glob(os.path.join(root, 'WellFedButton', '*.lua'))):
    for n, line in enumerate(open(path, encoding='utf-8'), 1):
        # Widget methods are PascalCase; lowercase ones are Lua string methods.
        for method in re.findall(r':([A-Z]\w*)\(', line):
            if method.isupper() or method.startswith(('PLAYER_', 'BAG_', 'GET_')):
                continue  # our event handlers
            if method not in documented and method not in known:
                bad.append('%s:%d  %s' % (os.path.relpath(path, root), n, method))

for b in bad:
    print('UNKNOWN METHOD ' + b)
print('method check: %d unknown' % len(bad))
sys.exit(1 if bad else 0)
