#version 450

layout (binding = 0) uniform sampler2D imageSampler;

layout (location = 0) in vec2 inUV;

layout (location = 0) out vec4 outColor;

// void main() 
// {
// 	outColor = texture(imageSampler, inUV);
// }

/*
	Denoiser source: https://www.shadertoy.com/view/7d2SDD
*/

layout (push_constant) uniform PushConstant {
	int samples;
	float distributionBias;
	float pixelMultiplier;
	float inversHueTolerance;
} pushConstant;

#define GOLDEN_ANGLE 2.3999632 //3PI-sqrt(5)PI

#define pow(a,b) pow(max(a,0.),b) // @morimea

mat2 sample2D = mat2(cos(GOLDEN_ANGLE), sin(GOLDEN_ANGLE), -sin(GOLDEN_ANGLE), cos(GOLDEN_ANGLE));

vec3 sirBirdDenoise() {
	ivec2 imageResolution = textureSize(imageSampler, 0);
    vec3 denoisedColor           = vec3(0.);
    
    const float sampleRadius     = sqrt(float(pushConstant.samples));
    const float sampleTrueRadius = 0.5/(sampleRadius*sampleRadius);
    vec2        samplePixel      = vec2(1.0/imageResolution.x,1.0/imageResolution.y); 
    vec3        sampleCenter     = texture(imageSampler, inUV).rgb;
    vec3        sampleCenterNorm = normalize(sampleCenter);
    float       sampleCenterSat  = length(sampleCenter);
    
    float  influenceSum = 0.0;
    float brightnessSum = 0.0;
    
    vec2 pixelRotated = vec2(0.,1.);
    
    for (float x = 0.0; x <= float(pushConstant.samples); x++) {
        
        pixelRotated *= sample2D;
        
        vec2  pixelOffset = pushConstant.pixelMultiplier * pixelRotated * sqrt(x) * 0.5;
        float pixelInfluence = 1.0 - sampleTrueRadius * pow(dot(pixelOffset, pixelOffset), pushConstant.distributionBias);
        pixelOffset *= samplePixel;
            
        vec3 thisDenoisedColor = texture(imageSampler, inUV + pixelOffset).rgb;

        pixelInfluence *= pixelInfluence*pixelInfluence;
        /*
            HUE + SATURATION FILTER
        */
        pixelInfluence *=   
            pow(0.5 + 0.5 * dot(sampleCenterNorm,normalize(thisDenoisedColor)), pushConstant.inversHueTolerance)
            * pow(1.0 - abs(length(thisDenoisedColor)-length(sampleCenterSat)),8.);
            
        influenceSum += pixelInfluence;
        denoisedColor += thisDenoisedColor*pixelInfluence;
    }
    
    return denoisedColor/influenceSum;
    
}

void main()
{
    vec3 col = sirBirdDenoise();
    
    outColor = vec4(col, 1.0);
}
