#pragma once

#include "../../../windows/mf_virtual_camera/gpu_frame_consumer.h"

class FrameGenerator
{
	iphone_camera::gpu_transport::GpuFrameConsumer _consumer;

public:
	FrameGenerator() = default;
	~FrameGenerator() = default;

	HRESULT SetD3DManager(IUnknown* manager, UINT width, UINT height);
	const bool HasD3DManager() const;
	HRESULT EnsureRenderTarget(UINT width, UINT height);
	HRESULT Generate(IMFSample* sample, REFGUID format, IMFSample** outSample);
};
