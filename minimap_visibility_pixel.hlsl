// -----------------------------------------------------------------------------
// Constant buffer providing per-pass visibility parameters.
// -----------------------------------------------------------------------------
CBUFFER_BEGIN( cminimap_visibility_pixel )
    float4 explored_tile;              // xy = player/explorer tile position, zw unused
    float4 tile_map_size;              // xy = total tile map size in world units, zw unused
    float4 visibility_map_size;        // xy = target visibility render texture size, zw unused
    float4 revealed_bound;             // xyzw = rectangle bounds for restricted reveal (optional)
    float  visibility_radius;          // scalar radius for visibility falloff (fog-of-war radius)

    float visibility_fully_revealed;   // >0.5 → force full visibility for all pixels
    float visibility_walkable_revealed;// >0.5 → reveal walkable area via walkability map
    float visibility_reset;            // >0.5 → engine requests a reset of visibility texture
    bool  use_revealed_bound;          // true → restrict visibility to revealed_bound rectangle
CBUFFER_END

// -----------------------------------------------------------------------------
// Texture bindings
// -----------------------------------------------------------------------------
TEXTURE2D_DECL( curr_visibility_sampler );  // previous frame's visibility texture
TEXTURE2D_DECL( walkability_sampler );      // static walkability data texture

// -----------------------------------------------------------------------------
// Input structure from rasterizer to pixel shader.
// -----------------------------------------------------------------------------
struct PS_INPUT
{
    float4 pixel_coord : SV_POSITION;  // screen-space pixel coordinate (x, y in pixels)
    float2 texture_uv  : TEXCOORD0;    // base UV for texture sampling
};

// -----------------------------------------------------------------------------
// Helper: RectDist()
// Returns Euclidean distance from a point (p) to a rectangle (rect).
// Used to clamp visibility inside a rectangular reveal bound.
// -----------------------------------------------------------------------------
float RectDist( float4 rect, float2 p )
{
    float dist_x = max(max(rect.x - p.x, p.x - rect.z), 0);
    float dist_y = max(max(rect.y - p.y, p.y - rect.w), 0);
    return length(float2(dist_x, dist_y));
}

// -----------------------------------------------------------------------------
// Main pixel shader: RenderVisibility()
// Computes per-pixel visibility ratio and blends it with previous visibility.
// -----------------------------------------------------------------------------
float4 RenderVisibility( const PS_INPUT input ) : PIXEL_RETURN_SEMANTIC
{
    // -------------------------------------------------------------------------
    // Normalize pixel coordinates into [0..1] UV space of the visibility map.
    // -------------------------------------------------------------------------
    float2 uv = input.pixel_coord.xy / visibility_map_size.xy;

    // Convert UV position to world/planar position within the tile map.
    float2 planar_pos = uv * tile_map_size.xy;

    // -------------------------------------------------------------------------
    // Compute Euclidean distance from this pixel to the currently explored tile.
    // -------------------------------------------------------------------------
    float dist = length(planar_pos - explored_tile.xy);

    // Optionally clamp visibility to a rectangular bound (if enabled).
    if (use_revealed_bound)
        dist = min(dist, RectDist(revealed_bound, planar_pos));

    // -------------------------------------------------------------------------
    // Compute local visibility ratio based on distance to explored center.
    // Saturate clamps to [0,1].
    // Formula:
    // 			ratio = (1 - dist / visibility_radius) * 2
    // 			Multiplier "2" steepens the falloff curve near the edge.
    // -------------------------------------------------------------------------
    float ratio = saturate((1.0f - dist / visibility_radius) * 2.0f);

    // -------------------------------------------------------------------------
    // Normalize pixel coordinate to viewport size for texture lookup.
    // -------------------------------------------------------------------------
    float2 viewport_size  = visibility_map_size.xy;
    float2 normalized_pos = input.pixel_coord.xy / viewport_size.xy;

    // -------------------------------------------------------------------------
    // Sample previously accumulated visibility (red channel only).
    // This texture persists explored data between frames.
    // -------------------------------------------------------------------------
    float prev_ratio = SAMPLE_TEX2D(curr_visibility_sampler, SamplerLinearClamp, normalized_pos).r;

    // -------------------------------------------------------------------------
    // Combine previous and current visibility ratios.
    // "max" ensures once a pixel is revealed, it remains revealed.
    // -------------------------------------------------------------------------
    float4 res_color = float4(max(ratio, prev_ratio), 0.0f, 0.0f, 1.0f);

    // -------------------------------------------------------------------------
    // Engine-triggered reset: perform a true reset to zero.
    // Returning a zeroed color ensures the engine does not flag
    // the visibility buffer as "non-reset" (which causes minimap wipes later).
    // -------------------------------------------------------------------------
    if (visibility_reset > 0.5f)
        return float4(0.0f, 0.0f, 0.0f, 1.0f);

    // -------------------------------------------------------------------------
    // Walkable area reveal mode (used for debugging or special states).
    // Merges walkable mask data into visibility.
    // -------------------------------------------------------------------------
    if (visibility_walkable_revealed > 0.5f)
    {
        float4 walkability_sample = SAMPLE_TEX2D(walkability_sampler, SamplerLinearClamp, uv);
        float  res_ratio          = (1.0f - saturate(walkability_sample.r));

        // Apply bound restriction if the rectangle has non-zero area.
        if (abs(revealed_bound.x - revealed_bound.z) + abs(revealed_bound.y - revealed_bound.w) > 1e-2f)
            res_ratio = max(prev_ratio, min(res_ratio, ratio));

        res_color = float4(max(prev_ratio, res_ratio), 0.0f, 0.0f, 1.0f);
    }

    // -------------------------------------------------------------------------
    // Engine "fully revealed" flag: forces visibility to maximum.
    // Only affects red channel to avoid state inconsistency across loads.
    // -------------------------------------------------------------------------
    if (visibility_fully_revealed > 0.5f)
        res_color.r = max(res_color.r, 1.0f);

    // -------------------------------------------------------------------------
    // Local adjustment: raise minimum visibility floor.
    // Ensures non-explored tiles remain faintly visible (~0.18 intensity)
    // without breaking persistent exploration logic.
    // This gives a light-gray overlay for unexplored regions while still
    // allowing real explored tiles to appear brighter.
    // -------------------------------------------------------------------------
    res_color.r = max(res_color.r, 0.18f);

    // -------------------------------------------------------------------------
    // Return final visibility color.
    // R = visibility intensity
    // G = unused (0)
    // B = unused (0)
    // A = constant 1.0 (opaque)
    // -------------------------------------------------------------------------
    return res_color;
}
