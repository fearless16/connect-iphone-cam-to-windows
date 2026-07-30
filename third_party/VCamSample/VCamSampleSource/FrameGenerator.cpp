#include "pch.h"
#include "FrameGenerator.h"

// This source deliberately has no drawing, WIC bitmap, RGB conversion, or
// CPU fallback. The iPhone receiver owns HEVC decode; the Windows Frame Server
// supplies the output sample and this class performs the one NV12 GPU copy.
HRESULT FrameGenerator::EnsureRenderTarget(UINT width, UINT height)
{
	RETURN_HR_IF(E_INVALIDARG, width != 3840 || height != 2160);
	return S_OK;
}

const bool FrameGenerator::HasD3DManager() const
{
	return true;
}

HRESULT FrameGenerator::SetD3DManager(IUnknown* manager, UINT width, UINT height)
{
	RETURN_HR_IF_NULL(E_POINTER, manager);
	RETURN_HR_IF(E_INVALIDARG, width != 3840 || height != 2160);
	return _consumer.SetDevice(manager);
}

HRESULT FrameGenerator::Generate(IMFSample* sample, REFGUID format, IMFSample** outSample)
{
	RETURN_HR_IF_NULL(E_POINTER, sample);
	RETURN_HR_IF_NULL(E_POINTER, outSample);
	*outSample = nullptr;
	RETURN_HR_IF(E_INVALIDARG, format != MFVideoFormat_NV12);

	LONGLONG timestamp = 0;
	LONGLONG duration = 0;
	bool discontinuity = false;
	RETURN_IF_FAILED(_consumer.CopyLatest(sample, &timestamp, &duration, &discontinuity));
	RETURN_IF_FAILED(sample->SetSampleTime(timestamp));
	RETURN_IF_FAILED(sample->SetSampleDuration(duration));
	if (discontinuity)
	{
		RETURN_IF_FAILED(sample->SetUINT32(MFSampleExtension_Discontinuity, TRUE));
	}
	sample->AddRef();
	*outSample = sample;
	return S_OK;
}
