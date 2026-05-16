// macFEMM modification notice:
// Modified by Linus Meierhoefer <linusmeierhoefer@protonmail.com>
// on 2026-05-16 to support native headless macOS/Linux builds.

// hsolvDlg.h : header file
//

#ifdef FEMM_HEADLESS
// In headless builds ChsolvDlg is aliased to ProgressReporter in mfc_compat.h.
#else

/////////////////////////////////////////////////////////////////////////////
// ChsolvDlg dialog

class ChsolvDlg : public CDialog {
  // Construction
  public:
  ChsolvDlg(CWnd* pParent = NULL); // standard constructor
  CString ComLine;

  // Dialog Data
  //{{AFX_DATA(ChsolvDlg)
  enum { IDD = IDD_HSOLV_DIALOG };
  CProgressCtrl m_prog2;
  CProgressCtrl m_prog1;
  //}}AFX_DATA

  // ClassWizard generated virtual function overrides
  //{{AFX_VIRTUAL(ChsolvDlg)
  protected:
  virtual void DoDataExchange(CDataExchange* pDX); // DDX/DDV support
  //}}AFX_VIRTUAL

  // Implementation
  protected:
  HICON m_hIcon;

  // Generated message map functions
  //{{AFX_MSG(ChsolvDlg)
  virtual void OnOK();
  virtual BOOL OnInitDialog();
  afx_msg void OnPaint();
  afx_msg HCURSOR OnQueryDragIcon();
  //}}AFX_MSG
  DECLARE_MESSAGE_MAP()
};

#endif // FEMM_HEADLESS
