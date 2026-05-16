// macFEMM modification notice:
// Modified by Linus Meierhoefer <linusmeierhoefer@protonmail.com>
// on 2026-05-16 to support native headless macOS/Linux builds.

// csolv.h : main header file for the CSOLV application
//

#ifdef FEMM_HEADLESS

void old_main(void* inptr);

#else

#ifndef __AFXWIN_H__
#error include 'stdafx.h' before including this file for PCH
#endif

#include "resource.h" // main symbols

void old_main(void* inptr);

/////////////////////////////////////////////////////////////////////////////
// CcsolvApp:
// See csolv.cpp for the implementation of this class
//

class CcsolvApp : public CWinApp {
  public:
  CcsolvApp();
  ~CcsolvApp();

  // Overrides
  // ClassWizard generated virtual function overrides
  //{{AFX_VIRTUAL(CcsolvApp)
  public:
  virtual BOOL InitInstance();
  //}}AFX_VIRTUAL

  // Implementation

  //{{AFX_MSG(CcsolvApp)
  // NOTE - the ClassWizard will add and remove member functions here.
  //    DO NOT EDIT what you see in these blocks of generated code !
  //}}AFX_MSG
  DECLARE_MESSAGE_MAP()
};

/////////////////////////////////////////////////////////////////////////////

#endif // FEMM_HEADLESS
