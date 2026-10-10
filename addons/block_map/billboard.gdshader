shader_type spatial;
render_mode cull_disabled, shadows_disabled;
// shadows_disabled: billboards still cast shadows, but receiving them makes a
// billboard shadow itself (the shadow pass turns it to face the light).

#include "res://addons/block_map/sprite.gdshaderinc"
