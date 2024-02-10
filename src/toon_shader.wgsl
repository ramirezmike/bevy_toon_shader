struct ToonShaderMaterial {
    color: vec4<f32>,
    sun_dir: vec3<f32>,
    sun_color: vec4<f32>,
    camera_pos: vec3<f32>,
    ambient_color: vec4<f32>,
};

@group(1) @binding(0)
var<uniform> material: ToonShaderMaterial;
@group(1) @binding(1)
var base_color_texture: texture_2d<f32>;
@group(1) @binding(2)
var base_color_sampler: sampler;

#import bevy_pbr::{
    prepass_bindings,
    mesh_functions,
    prepass_io::{Vertex, FragmentOutput},
    skinning,
    morph,
    mesh_view_bindings::{view, previous_view_proj},
}

#import bevy_pbr::forward_io::VertexOutput;
#import bevy_render::instance_index::get_instance_index

@vertex
fn vertex(vertex_no_morph: Vertex) -> VertexOutput {
    var out: VertexOutput;

#ifdef MORPH_TARGETS
    var vertex = morph_vertex(vertex_no_morph);
#else
    var vertex = vertex_no_morph;
#endif

#ifdef SKINNED
    var model = skinning::skin_model(vertex.joint_indices, vertex.joint_weights);
#else // SKINNED
    // Use vertex_no_morph.instance_index instead of vertex.instance_index to work around a wgpu dx12 bug.
    // See https://github.com/gfx-rs/naga/issues/2416
    var model = mesh_functions::get_model_matrix(vertex_no_morph.instance_index);
#endif // SKINNED

    out.position = mesh_functions::mesh_position_local_to_clip(model, vec4(vertex.position, 1.0));
#ifdef DEPTH_CLAMP_ORTHO
    out.clip_position_unclamped = out.position;
    out.position.z = min(out.position.z, 1.0);
#endif // DEPTH_CLAMP_ORTHO

#ifdef VERTEX_UVS
    out.uv = vertex.uv;
#endif // VERTEX_UVS

#ifdef NORMAL_PREPASS_OR_DEFERRED_PREPASS
#ifdef SKINNED
    out.world_normal = skinning::skin_normals(model, vertex.normal);
#else // SKINNED
    out.world_normal = mesh_functions::mesh_normal_local_to_world(
        vertex.normal,
        // Use vertex_no_morph.instance_index instead of vertex.instance_index to work around a wgpu dx12 bug.
        // See https://github.com/gfx-rs/naga/issues/2416
        get_instance_index(vertex_no_morph.instance_index)
    );
#endif // SKINNED

#ifdef VERTEX_TANGENTS
    out.world_tangent = mesh_functions::mesh_tangent_local_to_world(
        model,
        vertex.tangent,
        // Use vertex_no_morph.instance_index instead of vertex.instance_index to work around a wgpu dx12 bug.
        // See https://github.com/gfx-rs/naga/issues/2416
        get_instance_index(vertex_no_morph.instance_index)
    );
#endif // VERTEX_TANGENTS
#endif // NORMAL_PREPASS_OR_DEFERRED_PREPASS

#ifdef VERTEX_COLORS
    out.color = vertex.color;
#endif

#ifdef MOTION_VECTOR_PREPASS_OR_DEFERRED_PREPASS
    out.world_position = mesh_functions::mesh_position_local_to_world(model, vec4<f32>(vertex.position, 1.0));
#endif // MOTION_VECTOR_PREPASS_OR_DEFERRED_PREPASS

#ifdef MOTION_VECTOR_PREPASS
    // Use vertex_no_morph.instance_index instead of vertex.instance_index to work around a wgpu dx12 bug.
    // See https://github.com/gfx-rs/naga/issues/2416
    out.previous_world_position = mesh_functions::mesh_position_local_to_world(
        mesh_functions::get_previous_model_matrix(vertex_no_morph.instance_index),
        vec4<f32>(vertex.position, 1.0)
    );
#endif // MOTION_VECTOR_PREPASS

#ifdef VERTEX_OUTPUT_INSTANCE_INDEX
    // Use vertex_no_morph.instance_index instead of vertex.instance_index to work around a wgpu dx12 bug.
    // See https://github.com/gfx-rs/naga/issues/2416
    out.instance_index = get_instance_index(vertex_no_morph.instance_index);
#endif
#ifdef BASE_INSTANCE_WORKAROUND
    // Hack: this ensures the push constant is always used, which works around this issue:
    // https://github.com/bevyengine/bevy/issues/10509
    // This can be removed when wgpu 0.19 is released
    out.position.x += min(f32(get_instance_index(0u)), 0.0);
#endif

    return out;
}

@fragment
fn fragment (in: VertexOutput) -> @location(0) vec4<f32> {
    let base_color = material.color * textureSample(base_color_texture, base_color_sampler, in.uv);
    let normal = normalize(in.world_normal);
    let n_dot_l = dot(material.sun_dir, normal);
    var light_intensity = 0.0;

    if n_dot_l > 0.0 {
        let bands = 3.0;
        var x = n_dot_l * bands;

        x = round(x);

        light_intensity = x / bands;
    } else {
        light_intensity = 0.0;
    }

    let light = light_intensity * material.sun_color;

    let view_dir: vec3<f32> = normalize(material.camera_pos - in.world_position.xyz);

    let half_vector = normalize(material.sun_dir + view_dir);
    let n_dot_h = dot(normal, half_vector);
    let glossiness = 32.0;
    let specular_intensity = pow(n_dot_h, glossiness * glossiness);

    let specular_intensity_smooth = smoothstep(0.005, 0.01, specular_intensity);
    let specular = specular_intensity_smooth * vec4<f32>(0.9, 0.9 ,0.9 ,1.0);

    return base_color * (light + material.ambient_color + specular);
}
