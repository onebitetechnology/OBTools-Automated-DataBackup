Option Explicit

Dim shell, command, index

If WScript.Arguments.Count < 1 Then
  WScript.Quit 64
End If

Set shell = CreateObject("WScript.Shell")
command = QuoteArgument("powershell.exe") & _
  " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & _
  QuoteArgument(WScript.Arguments(0))

For index = 1 To WScript.Arguments.Count - 1
  command = command & " " & QuoteArgument(WScript.Arguments(index))
Next

WScript.Quit shell.Run(command, 0, True)

Function QuoteArgument(value)
  QuoteArgument = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
