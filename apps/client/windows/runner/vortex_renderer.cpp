#include "vortex_renderer.h"

#include <d3d11.h>
#include <dcomp.h>
#include <dxgi1_3.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <thread>
#include <utility>
#include <vector>

#include "GlintPS.h"
#include "GlintVS.h"
#include "SheetPS.h"
#include "SheetVS.h"

using Microsoft::WRL::ComPtr;

#ifdef WG_VORTEX_PROBE
void VortexProbePresented();
#endif

namespace {
constexpr auto kWindowClass = L"WeekGlassVortexSurface";
constexpr int kCols = 96, kRows = 64;
constexpr UINT kIndexCount = kCols * kRows * 6;

LRESULT CALLBACK OverlayProc(HWND window, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_NCHITTEST: return HTTRANSPARENT;
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
      PAINTSTRUCT ps{};
      BeginPaint(window, &ps);
      EndPaint(window, &ps);
      return 0;
    }
  }
  return DefWindowProcW(window, msg, wp, lp);
}

bool RegisterOverlay() {
  static const bool registered = [] {
    WNDCLASSW wc{};
    wc.lpfnWndProc = OverlayProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kWindowClass;
    return RegisterClassW(&wc) || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
  }();
  return registered;
}

struct Frame {
  float canvas[2], origin[2];
  float size[2], sink[2];
  float axis[2], spin, openness;
  float texel[2], reduced, density;
  float intake_inward[2], padding[2];
};
static_assert(sizeof(Frame) == 5*16);

RECT OverlayBounds(RECT source, POINT anchor) {
  // Allow lateral sweep outside a normal window. The virtual desktop clips
  // only unobservable pixels and permits a taskbar on a different monitor.
  const LONG margin = static_cast<LONG>(std::ceil(.35 * std::hypot(
      source.right-source.left, source.bottom-source.top)));
  const LONG left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const LONG top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  return {std::max(left, std::min(source.left, anchor.x)-margin),
          std::max(top, std::min(source.top, anchor.y)-margin),
          std::min(left+GetSystemMetrics(SM_CXVIRTUALSCREEN),
                   std::max(source.right, anchor.x+1)+margin),
          std::min(top+GetSystemMetrics(SM_CYVIRTUALSCREEN),
                   std::max(source.bottom, anchor.y+1)+margin)};
}
}  // namespace

struct VortexRenderer::State {
  HWND overlay = nullptr;
  bool shown = false;
  Frame frame{};
  ComPtr<ID3D11Device> gpu;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<IDXGIFactory2> factory;
  ComPtr<IDXGISwapChain1> chain;
  HANDLE frame_ready = nullptr;
  ComPtr<IDCompositionDevice> composition;
  ComPtr<IDCompositionTarget> target;
  ComPtr<IDCompositionVisual> visual;
  ComPtr<ID3D11RenderTargetView> rtv;
  ComPtr<ID3D11DepthStencilView> depth;
  ComPtr<ID3D11ShaderResourceView> snapshot;
  ComPtr<ID3D11Buffer> indices, uniforms;
  ComPtr<ID3D11VertexShader> sheet_vs, glint_vs;
  ComPtr<ID3D11PixelShader> sheet_ps, glint_ps;
  ComPtr<ID3D11RasterizerState> raster;
  ComPtr<ID3D11BlendState> over;
  ComPtr<ID3D11SamplerState> sampler;

  ~State() { Reset(false); }

  void Reset(bool retain) {
    if (overlay) {
      ShowWindow(overlay, SW_HIDE);
      shown = false;
      if (retain) return;
      DestroyWindow(overlay);
      overlay = nullptr;
    }
    if (context) context->ClearState();
    if (frame_ready) CloseHandle(std::exchange(frame_ready, nullptr));
    visual.Reset(); target.Reset(); chain.Reset();
    rtv.Reset(); depth.Reset(); snapshot.Reset();
  }

  bool InitDevice() {
    // No software rasterizer on UI-thread animation. Native window behavior
    // remains available on systems without a suitable hardware device.
    constexpr D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,D3D_FEATURE_LEVEL_10_0};
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, ARRAYSIZE(levels),
        D3D11_SDK_VERSION, &gpu, nullptr, &context))) return false;
    ComPtr<IDXGIDevice1> dxgi;
    ComPtr<IDXGIAdapter> adapter;
    return SUCCEEDED(gpu.As(&dxgi)) && SUCCEEDED(dxgi->GetAdapter(&adapter)) &&
        SUCCEEDED(adapter->GetParent(IID_PPV_ARGS(&factory))) &&
        SUCCEEDED(DCompositionCreateDevice(dxgi.Get(), IID_PPV_ARGS(&composition))) &&
        Pipeline();
  }

  bool InitSurface(HWND owner, RECT bounds, POINT anchor, const uint8_t* pixels,
                   int texture_width, int texture_height) {
    const RECT region = OverlayBounds(bounds, anchor);
    const int width = region.right-region.left, height = region.bottom-region.top;
    if (width <= 0 || height <= 0 || !RegisterOverlay()) return false;
    const DWORD styles = WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT |
                         WS_EX_LAYERED | WS_EX_NOREDIRECTIONBITMAP;
    // An owned popup would be hidden by Windows when its owner minimizes.
    overlay = CreateWindowExW(styles, kWindowClass, L"", WS_POPUP,
        region.left, region.top, width, height, nullptr, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    if (!overlay || !SetLayeredWindowAttributes(overlay, 0, 255, LWA_ALPHA)) return false;

    frame.canvas[0] = static_cast<float>(width);
    frame.canvas[1] = static_cast<float>(height);
    frame.origin[0] = static_cast<float>(bounds.left-region.left);
    frame.origin[1] = static_cast<float>(bounds.top-region.top);
    frame.size[0] = static_cast<float>(bounds.right-bounds.left);
    frame.size[1] = static_cast<float>(bounds.bottom-bounds.top);
    frame.sink[0] = static_cast<float>(anchor.x-region.left);
    frame.sink[1] = static_cast<float>(anchor.y-region.top);
    const float dx = frame.origin[0]+frame.size[0]*.5f-frame.sink[0];
    const float dy = frame.origin[1]+frame.size[1]*.5f-frame.sink[1];
    const float length = std::hypot(dx,dy);
    frame.axis[0] = length > 1 ? dx/length : 0.f;
    frame.axis[1] = length > 1 ? dy/length : -1.f;
    // Turn towards the interior when the taskbar point hugs a screen edge.
    MONITORINFO monitor{sizeof(MONITORINFO), {}, {}, 0};
    const bool has_monitor = GetMonitorInfoW(MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST), &monitor) != FALSE;
    const float mx = static_cast<float>(monitor.rcMonitor.left+monitor.rcMonitor.right)*.5f;
    const float my = static_cast<float>(monitor.rcMonitor.top+monitor.rcMonitor.bottom)*.5f;
    frame.spin = (mx-anchor.x)*-frame.axis[1]+(my-anchor.y)*frame.axis[0] >= 0 ? 1.f : -1.f;
    frame.texel[0] = 1.f/static_cast<float>(texture_width);
    frame.texel[1] = 1.f/static_cast<float>(texture_height);
    frame.density = static_cast<float>(GetDpiForWindow(owner))/96.f;
    frame.intake_inward[0] = frame.intake_inward[1] = 0.f;
    if (has_monitor) {
      const RECT& r = monitor.rcMonitor;
      const LONG gaps[] = {std::abs(anchor.y-r.bottom), std::abs(anchor.y-r.top),
                           std::abs(anchor.x-r.left), std::abs(anchor.x-r.right)};
      const int edge = static_cast<int>(std::min_element(gaps,gaps+4)-gaps);
      if (gaps[edge] <= 84.f*frame.density) {
        constexpr float inward[][2] = {{0,-1},{0,1},{1,0},{-1,0}};
        frame.intake_inward[0] = inward[edge][0];
        frame.intake_inward[1] = inward[edge][1];
      }
    }

    DXGI_SWAP_CHAIN_DESC1 swap{};
    swap.Width = width;
    swap.Height = height;
    swap.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    swap.SampleDesc.Count = 1;
    swap.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap.BufferCount = 2;
    swap.Scaling = DXGI_SCALING_STRETCH;
    swap.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    swap.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    swap.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    ComPtr<IDXGISwapChain2> paced;
    if (FAILED(factory->CreateSwapChainForComposition(gpu.Get(), &swap, nullptr, &chain)) ||
        FAILED(chain.As(&paced)) || FAILED(paced->SetMaximumFrameLatency(1)) ||
        !(frame_ready = paced->GetFrameLatencyWaitableObject()) ||
        FAILED(composition->CreateTargetForHwnd(overlay, TRUE, &target)) ||
        FAILED(composition->CreateVisual(&visual)) ||
        FAILED(visual->SetContent(chain.Get())) || FAILED(target->SetRoot(visual.Get())) ||
        FAILED(composition->Commit())) return false;
    ComPtr<ID3D11Texture2D> back, z;
    D3D11_TEXTURE2D_DESC depth_desc{};
    depth_desc.Width = width;
    depth_desc.Height = height;
    depth_desc.ArraySize = depth_desc.MipLevels = depth_desc.SampleDesc.Count = 1;
    depth_desc.Format = DXGI_FORMAT_D16_UNORM;
    depth_desc.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    if (FAILED(chain->GetBuffer(0, IID_PPV_ARGS(&back))) ||
        FAILED(gpu->CreateRenderTargetView(back.Get(), nullptr, &rtv)) ||
        FAILED(gpu->CreateTexture2D(&depth_desc, nullptr, &z)) ||
        FAILED(gpu->CreateDepthStencilView(z.Get(), nullptr, &depth))) return false;
    return Upload(pixels, texture_width, texture_height);
  }

  bool Upload(const uint8_t* pixels, int width, int height) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width;
    desc.Height = height;
    desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    desc.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
    ComPtr<ID3D11Texture2D> texture;
    if (FAILED(gpu->CreateTexture2D(&desc,nullptr,&texture)) ||
        FAILED(gpu->CreateShaderResourceView(texture.Get(),nullptr,&snapshot))) return false;
    context->UpdateSubresource(texture.Get(),0,nullptr,pixels,static_cast<UINT>(width)*4,0);
    context->GenerateMips(snapshot.Get());
    return true;
  }

  bool Pipeline() {
    if (FAILED(gpu->CreateVertexShader(kSheetVS,sizeof(kSheetVS),nullptr,&sheet_vs)) ||
        FAILED(gpu->CreatePixelShader(kSheetPS,sizeof(kSheetPS),nullptr,&sheet_ps)) ||
        FAILED(gpu->CreateVertexShader(kGlintVS,sizeof(kGlintVS),nullptr,&glint_vs)) ||
        FAILED(gpu->CreatePixelShader(kGlintPS,sizeof(kGlintPS),nullptr,&glint_ps))) return false;
    std::vector<uint16_t> grid;
    grid.reserve(kIndexCount);
    for (int y=0; y<kRows; ++y) {
      for (int x=0; x<kCols; ++x) {
        const auto a = static_cast<uint16_t>(y*(kCols+1)+x);
        const auto b = static_cast<uint16_t>(a+1);
        const auto c = static_cast<uint16_t>(a+kCols+1);
        const auto d = static_cast<uint16_t>(c+1);
        grid.insert(grid.end(),{a,b,c,b,d,c});
      }
    }
    D3D11_BUFFER_DESC ib{};
    ib.ByteWidth = static_cast<UINT>(grid.size()*sizeof(uint16_t));
    ib.Usage = D3D11_USAGE_IMMUTABLE;
    ib.BindFlags = D3D11_BIND_INDEX_BUFFER;
    D3D11_SUBRESOURCE_DATA mesh{grid.data(),0,0};
    D3D11_BUFFER_DESC cb{};
    cb.ByteWidth = sizeof(Frame);
    cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    D3D11_RASTERIZER_DESC rs{};
    rs.FillMode = D3D11_FILL_SOLID;
    rs.CullMode = D3D11_CULL_NONE;
    rs.DepthClipEnable = TRUE;
    D3D11_BLEND_DESC blend{};
    auto& dst = blend.RenderTarget[0];
    dst.BlendEnable = TRUE;
    dst.SrcBlend = dst.SrcBlendAlpha = D3D11_BLEND_ONE;
    dst.DestBlend = dst.DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    dst.BlendOp = dst.BlendOpAlpha = D3D11_BLEND_OP_ADD;
    dst.RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    D3D11_SAMPLER_DESC sample{};
    sample.Filter = D3D11_FILTER_ANISOTROPIC;
    sample.MaxAnisotropy = 4;
    sample.AddressU = sample.AddressV = sample.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sample.ComparisonFunc = D3D11_COMPARISON_NEVER;
    sample.MaxLOD = D3D11_FLOAT32_MAX;
    return SUCCEEDED(gpu->CreateBuffer(&ib,&mesh,&indices)) &&
           SUCCEEDED(gpu->CreateBuffer(&cb,nullptr,&uniforms)) &&
           SUCCEEDED(gpu->CreateRasterizerState(&rs,&raster)) &&
           SUCCEEDED(gpu->CreateBlendState(&blend,&over)) &&
           SUCCEEDED(gpu->CreateSamplerState(&sample,&sampler));
  }

  void Paint(float openness, bool reduced) {
    frame.openness = std::clamp(openness,0.f,1.f);
    frame.reduced = reduced ? 1.f : 0.f;
    const float clear[4]{};
    context->ClearRenderTargetView(rtv.Get(),clear);
    if (frame.openness == 0.f) return;
    D3D11_VIEWPORT viewport{0,0,frame.canvas[0],frame.canvas[1],0,1};
    context->RSSetViewports(1,&viewport);
    context->RSSetState(raster.Get());
    context->ClearDepthStencilView(depth.Get(),D3D11_CLEAR_DEPTH,1.f,0);
    context->OMSetRenderTargets(1,rtv.GetAddressOf(),depth.Get());
    context->OMSetBlendState(nullptr,nullptr,0xffffffff);
    context->UpdateSubresource(uniforms.Get(),0,nullptr,&frame,0,0);
    context->VSSetConstantBuffers(0,1,uniforms.GetAddressOf());
    context->PSSetConstantBuffers(0,1,uniforms.GetAddressOf());
    context->PSSetSamplers(0,1,sampler.GetAddressOf());
    context->PSSetShaderResources(0,1,snapshot.GetAddressOf());
    context->IASetIndexBuffer(indices.Get(),DXGI_FORMAT_R16_UINT,0);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetShader(sheet_vs.Get(),nullptr,0);
    context->PSSetShader(sheet_ps.Get(),nullptr,0);
    context->DrawIndexed(kIndexCount,0,0);
    if (!reduced && frame.openness < .90f && frame.openness > .09f) {
      context->OMSetRenderTargets(1,rtv.GetAddressOf(),nullptr);
      context->OMSetBlendState(over.Get(),nullptr,0xffffffff);
      context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
      context->VSSetShader(glint_vs.Get(),nullptr,0);
      context->PSSetShader(glint_ps.Get(),nullptr,0);
      context->DrawInstanced(4,8,0,0);
    }
  }
};

struct VortexRenderer::Warmup {
  std::atomic<bool> ready{false};
  std::unique_ptr<State> state;
};

VortexRenderer::VortexRenderer() = default;
VortexRenderer::~VortexRenderer() = default;

void VortexRenderer::Warm(HWND owner, UINT ready_message, WPARAM token) {
  if (state_ && SUCCEEDED(state_->gpu->GetDeviceRemovedReason())) return;
  if (warmup_) return;
  state_.reset();
  auto warmup = std::make_shared<Warmup>();
  try {
    std::thread([owner, ready_message, token, warmup] {
      try {
        auto state = std::make_unique<State>();
        if (state->InitDevice()) warmup->state = std::move(state);
      } catch (...) {}
      warmup->ready.store(true);
      PostMessageW(owner, ready_message, token, 0);
    }).detach();
    warmup_ = std::move(warmup);
  } catch (...) {}
}

bool VortexRenderer::warming() const {
  return warmup_ && !warmup_->ready.load();
}

bool VortexRenderer::Prepare(HWND owner, RECT bounds, POINT anchor,
                             const uint8_t* rgba, int width, int height) {
  Reset();
  if (!IsWindow(owner) || !rgba || width <= 0 || height <= 0 ||
      IsRectEmpty(&bounds)) return false;
  if (warmup_ && warmup_->ready.load()) {
    state_ = std::move(warmup_->state);
    warmup_.reset();
  }
  return state_ && state_->InitSurface(owner,bounds,anchor,rgba,width,height);
}

HANDLE VortexRenderer::frame_ready() const {
  return state_ ? state_->frame_ready : nullptr;
}

VortexRenderer::Result VortexRenderer::Draw(float openness, bool reduced) {
  if (!frame_ready()) return Result::unavailable;
  auto& s = *state_;
  s.Paint(openness,reduced);
  const HRESULT presented = s.chain->Present(1,DXGI_PRESENT_DO_NOT_WAIT);
  if (presented == DXGI_ERROR_WAS_STILL_DRAWING) return Result::busy;
  if (FAILED(presented)) return Result::unavailable;
  if (!s.shown) {
    // Minimizing transfers activation *after* this first present. An ordinary
    // HWND_TOP popup is immediately obscured by the newly raised app. Only
    // the alpha-composited, click-through sheet enters the topmost band, and
    // Reset hides it at the end of the transition. Never raise the planner.
    if (!SetWindowPos(s.overlay,HWND_TOPMOST,0,0,0,0,SWP_NOMOVE | SWP_NOSIZE |
                      SWP_NOACTIVATE | SWP_SHOWWINDOW)) return Result::unavailable;
    s.shown = true;
  }
#ifdef WG_VORTEX_PROBE
  VortexProbePresented();
#endif
  return Result::presented;
}

void VortexRenderer::Reset(bool retain) {
  if (state_) state_->Reset(retain);
}

void VortexRenderer::Release() {
  state_.reset();
  warmup_.reset();
}
