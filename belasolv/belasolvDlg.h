// macFEMM modification notice:
// Modified by Linus Meierhoefer <linusmeierhoefer@protonmail.com>
// on 2026-05-16 to support native headless macOS/Linux builds.

// belasolvDlg.h : header file
//

#ifdef FEMM_HEADLESS
// In headless builds CbelasolvDlg is aliased to ProgressReporter in
// mfc_compat.h. No class declaration is needed — the math code only touches
// CbelasolvDlg through a pointer and calls setStatus/setFrame/setProgress.
#else

/////////////////////////////////////////////////////////////////////////////
// CbelasolvDlg dialog

class CbelasolvDlg : public CDialog {
  // Construction
  public:
  CbelasolvDlg(CWnd* pParent = NULL); // standard constructor
  CString ComLine;

  // Dialog Data
  //{{AFX_DATA(CbelasolvDlg)
  enum { IDD = IDD_BELASOLV_DIALOG };
  CProgressCtrl m_prog1;
  //}}AFX_DATA

  // ClassWizard generated virtual function overrides
  //{{AFX_VIRTUAL(CbelasolvDlg)
  protected:
  virtual void DoDataExchange(CDataExchange* pDX); // DDX/DDV support
  //}}AFX_VIRTUAL

  // Implementation
  protected:
  HICON m_hIcon;

  // Generated message map functions
  //{{AFX_MSG(CbelasolvDlg)
  virtual void OnOK();
  virtual BOOL OnInitDialog();
  afx_msg void OnPaint();
  afx_msg HCURSOR OnQueryDragIcon();
  //}}AFX_MSG
  DECLARE_MESSAGE_MAP()
};

#endif // FEMM_HEADLESS
