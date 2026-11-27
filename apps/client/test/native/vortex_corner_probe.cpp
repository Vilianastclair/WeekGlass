// Sample the shipping GPU pipeline before the composition swap. All windows
// belong to an inactive desktop; no user window is captured.
#include "vortex_renderer.h"
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
using Microsoft::WRL::ComPtr;
namespace {
bool rounded = true;
float phase;
constexpr int side = 20;
void Require(bool ok, const char* reason) {
  if (!ok) { std::fprintf(stderr,"FAIL: %s\n",reason); std::exit(2); }
}
}
void VortexProbePixels(ID3D11Device* device, ID3D11DeviceContext* context,
                       IDXGISwapChain1* chain, RECT r) {
  ComPtr<ID3D11Texture2D> back, sample;
  Require(SUCCEEDED(chain->GetBuffer(0,IID_PPV_ARGS(&back))), "swap texture");
  D3D11_TEXTURE2D_DESC desc{};
  back->GetDesc(&desc);
  desc.Width = desc.Height = side;
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = desc.MiscFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  Require(SUCCEEDED(device->CreateTexture2D(&desc,nullptr,&sample)), "corner readback");
  const int opacity = static_cast<int>(std::round(phase*255));
  std::array<int,4> outer{};
  for (int i=0; i<4; i++) {
    const auto x = static_cast<UINT>(i&1 ? r.right-side : r.left);
    const auto y = static_cast<UINT>(i&2 ? r.bottom-side : r.top);
    const D3D11_BOX box{x,y,0,x+side,y+side,1};
    context->CopySubresourceRegion(sample.Get(),0,0,0,0,back.Get(),0,&box);
    D3D11_MAPPED_SUBRESOURCE data{};
    Require(SUCCEEDED(context->Map(sample.Get(),0,D3D11_MAP_READ,0,&data)), "map corner");
    auto alpha = [&](int dx,int dy) -> int {
      const int ix = i&1 ? side-1-dx : dx, iy = i&2 ? side-1-dy : dy;
      const auto* bytes = static_cast<const BYTE*>(data.pData)+iy*data.RowPitch+4*ix;
      Require(bytes[0]<=bytes[3] && bytes[1]<=bytes[3] && bytes[2]<=bytes[3], "premultiplied color");
      return bytes[3];
    };
    outer[i] = alpha(0,0);
    Require(outer[i]==(rounded ? 0 : opacity), "outside corner alpha");
    Require(std::abs(alpha(side-1,0)-opacity)<=1 && std::abs(alpha(0,side-1)-opacity)<=1, "straight edges");
    if (rounded && i==0 && phase==1.f) {
      int partial = 0;
      FILE* crop = nullptr;
      fopen_s(&crop,"gentle-corner.pgm","wb");
      Require(crop!=nullptr, "write corner image");
      std::fprintf(crop,"P5\n%d %d\n255\n",side,side);
      for (int dy=0;dy<side;dy++) for (int dx=0;dx<side;dx++) {
        const int a=alpha(dx,dy);
        partial += a>0 && a<255;
        std::fputc(a,crop);
      }
      std::fclose(crop);
      Require(partial>0, "antialiasing");
    }
    context->Unmap(sample.Get(),0);
  }
  std::printf("%s phase %.2f four corner alphas %d %d %d %d, edge %d\n",
      rounded?"restored":"maximized",phase,outer[0],outer[1],outer[2],outer[3],opacity);
}
int main() {
  const auto desktop = CreateDesktopW(L"WeekGlassCornerTest",nullptr,nullptr,0,GENERIC_ALL,nullptr);
  Require(desktop && SetThreadDesktop(desktop), "private desktop");
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  HWND owner = CreateWindowW(L"STATIC",L"WeekGlass corner test",WS_OVERLAPPEDWINDOW,
      40,40,640,480,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  Require(owner!=nullptr, "test window");
  {
    VortexRenderer screen;
    screen.Warm(owner,WM_APP+1,0);
    for (int i=0; i<500 && screen.warming(); ++i) Sleep(10);
    std::vector<uint8_t> white(320*200*4,255);
    for (const bool normal : {true,false}) {
      rounded=normal;
      ShowWindow(owner,normal ? SW_SHOWNOACTIVATE : SW_MAXIMIZE);
      Require((IsZoomed(owner)!=FALSE)==!normal,"window placement");
      Require(screen.Prepare(owner,{80,80,400,280},{250,210},white.data(),320,200),"GPU preparation");
      for (float p : {1.f,.75f,.5f,.25f,0.f,.25f,.5f,.75f,1.f}) {
        phase=p;
        Require(WaitForSingleObject(screen.frame_ready(),1000)==WAIT_OBJECT_0,"frame slot");
        Require(screen.Draw(phase,true)==VortexRenderer::Result::presented,"frame presentation");
      }
      phase=1.f;
      Require(WaitForSingleObject(screen.frame_ready(),1000)==WAIT_OBJECT_0,"handoff slot");
      Require(screen.Draw(phase,false)==VortexRenderer::Result::presented,"liquid handoff");
    }
  }
  DestroyWindow(owner);
}
