{*******************************************************************************
  Yutani Universe Former Demo Form
********************************************************************************
  Minimal VCL host for the Yutani.Worlds.Space.UniverseFormer engine.

  The form provides a parent HWND (pnlRender) for the embedded Raylib
  window, forwards resize events, and hosts the Save/Load dialogs.

  There are NO VCL toolbar buttons anymore - Save/Load live inside the
  Raylib HUD (bottom-left buttons). When the user clicks one, the
  engine fires OnSaveRequested / OnLoadRequested, and this form opens
  the matching TOpenDialog / TSaveDialog and calls back into the
  engine's SaveToFile / LoadFromFile.

  Author: Lara Miriam Tamy Reschke / LamitaOne
*******************************************************************************}

unit Unit1;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, Vcl.Controls, Vcl.Forms,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Dialogs, raylib, UniverseFormerSample,
  Yutani.Worlds.Space.UniverseFormer;

type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private
    FEngine: TUniverseFormerSample;
    pnlRender: TPanel;
    dlgOpen: TOpenDialog;
    dlgSave: TSaveDialog;
    // Called by the engine when the user clicks the in-Raylib HUD
    // Save/Load buttons. We open the matching VCL dialog and call
    // back into the engine.
    procedure OnHUDSave;
    procedure OnHUDLoad;
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

procedure TForm1.FormCreate(Sender: TObject);
begin
  Caption := 'Yutani Universe Former';
  Self.DoubleBuffered := True;
  Width := 1280;
  Height := 800;
  Position := poScreenCenter;

  // Render Panel - hosts the Raylib child window. The Raylib HUD
  // (toolbar + status bar) is rendered inside this panel, so the
  // entire form client area is the universe viewport.
  pnlRender := TPanel.Create(Self);
  pnlRender.Parent := Self;
  pnlRender.Align := alClient;
  pnlRender.BevelOuter := bvNone;
  pnlRender.Caption := '';

  // Dialogs - opened by OnHUDSave / OnHUDLoad when the user clicks
  // the in-Raylib Save/Load buttons.
  dlgOpen := TOpenDialog.Create(Self);
  dlgOpen.Filter := 'SQLite Database (*.sqlite)|*.sqlite|All Files (*.*)|*.*';
  dlgOpen.DefaultExt := 'sqlite';
  dlgOpen.Title := 'Load Universe';

  dlgSave := TSaveDialog.Create(Self);
  dlgSave.Filter := 'SQLite Database (*.sqlite)|*.sqlite|All Files (*.*)|*.*';
  dlgSave.DefaultExt := 'sqlite';
  dlgSave.Title := 'Save Universe';

  // Instantiate the engine suspended. FormShow starts it.
  FEngine := TUniverseFormerSample.Create(pnlRender.Handle);
  FEngine.SetDimensions(pnlRender.ClientWidth, pnlRender.ClientHeight);
  FEngine.SetFPS(60);

  // Subscribe to the HUD button callbacks BEFORE StartEngine so
  // they're already in place when the worker thread spins up.
  FEngine.OnSaveRequested := OnHUDSave;
  FEngine.OnLoadRequested := OnHUDLoad;
end;

procedure TForm1.FormShow(Sender: TObject);
begin
  if Assigned(FEngine) then
    FEngine.StartEngine;
end;

procedure TForm1.FormResize(Sender: TObject);
begin
  if Assigned(FEngine) and Assigned(pnlRender) then
    FEngine.SetDimensions(pnlRender.ClientWidth, pnlRender.ClientHeight);
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  if Assigned(FEngine) then
  begin
    FEngine.StopEngine;
    FEngine.Terminate;
    FEngine.WaitFor;
    FEngine.Free;
  end;
end;

procedure TForm1.OnHUDSave;
begin
  // Called from the worker thread via the engine's callback. The
  // VCL dialog must run on the main thread, so we TThread.Queue
  // ourselves onto the main thread before calling Execute.
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FEngine) and dlgSave.Execute then
        FEngine.SaveToFile(dlgSave.FileName);
    end);
end;

procedure TForm1.OnHUDLoad;
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FEngine) and dlgOpen.Execute then
        FEngine.LoadFromFile(dlgOpen.FileName);
    end);
end;

end.

