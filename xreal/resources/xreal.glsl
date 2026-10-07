//!PARAM xreal_mode
//!TYPE int
//!MINIMUM 0
//!MAXIMUM 5
0

//!PARAM eye_aspect
//!TYPE float
//!MINIMUM 0.1
//!MAXIMUM 10.0
1.7777778

//!PARAM swap_eyes
//!TYPE int
//!MINIMUM 0
//!MAXIMUM 1
0

//!PARAM yaw
//!TYPE float
//!MINIMUM -180.0
//!MAXIMUM 180.0
0.0

//!PARAM pitch
//!TYPE float
//!MINIMUM -85.0
//!MAXIMUM 85.0
0.0

//!PARAM fov
//!TYPE float
//!MINIMUM 35.0
//!MAXIMUM 110.0
70.0

//!HOOK MAIN
//!BIND HOOKED
//!DESC XREAL separate-eye projection
//!WIDTH 3840
//!HEIGHT 1080
const float PI = 3.141592653589793;

vec4 hook() {
    float eye = step(0.5, HOOKED_pos.x);
    vec2 uv = vec2(fract(HOOKED_pos.x * 2.0), HOOKED_pos.y);
    if (swap_eyes == 1) eye = 1.0 - eye;
    bool top_bottom = xreal_mode == 4 || xreal_mode == 5;

    if (xreal_mode < 2) {
        // Fit each view separately. Padding the combined SBS frame would mix
        // the two eye boundaries for letterboxed movies.
        float frame_aspect = 16.0 / 9.0;
        if (eye_aspect > frame_aspect) {
            uv.y = (uv.y - 0.5) * eye_aspect / frame_aspect + 0.5;
        } else {
            uv.x = (uv.x - 0.5) * frame_aspect / eye_aspect + 0.5;
        }
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
            return vec4(0.0, 0.0, 0.0, 1.0);
    } else {
        // Rectilinear viewport -> equirectangular panorama, independently for
        // each eye. No CPU v360 filter or readback of decoded 8K frames.
        vec2 xy = (uv * 2.0 - 1.0) * tan(radians(fov) * 0.5);
        vec3 ray = normalize(vec3(xy.x, -xy.y * 9.0 / 16.0, 1.0));
        float p = radians(pitch);
        ray.yz = mat2(cos(p), -sin(p), sin(p), cos(p)) * ray.yz;
        float y = radians(yaw);
        ray.xz = mat2(cos(y), -sin(y), sin(y), cos(y)) * ray.xz;
        float longitude = atan(ray.x, ray.z);
        float latitude = asin(clamp(ray.y, -1.0, 1.0));
        bool half_sphere = xreal_mode == 2 || xreal_mode == 4;
        if (half_sphere && abs(longitude) > PI * 0.5)
            return vec4(0.0, 0.0, 0.0, 1.0);
        uv = vec2(longitude / (half_sphere ? PI : 2.0 * PI) + 0.5,
                  0.5 - latitude / PI);
    }

    // Clamp at the edge of the chosen eye, avoiding interpolation with the
    // other view at the SBS/TB boundary.
    vec2 eye_size = HOOKED_size / (top_bottom ? vec2(1.0, 2.0) : vec2(2.0, 1.0));
    uv = clamp(uv, 0.5 / eye_size, 1.0 - 0.5 / eye_size);
    vec2 source = top_bottom ? vec2(uv.x, (uv.y + eye) * 0.5)
                            : vec2((uv.x + eye) * 0.5, uv.y);
    return HOOKED_tex(source);
}
