program Project1;

uses
  Vcl.Forms,
  Unit1 in 'Unit1.pas' {Form1},
  UniverseFormerSample in 'UniverseFormerSample.pas',
  Yutani.Worlds.Space.UniverseFormer in 'Yutani.Worlds.Space.UniverseFormer.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
