#!/usr/bin/env python3
import subprocess
import json

def focus_hermes():
    try:
        res = subprocess.run(["niri", "msg", "--json", "windows"], capture_output=True, text=True)
        windows = json.loads(res.stdout)
        
        hermes_win = None
        for w in windows:
            title = str(w.get("title", ""))
            app_id = str(w.get("app_id", ""))
            if app_id == "Hermes" or title == "Hermes":
                hermes_win = w
                break
        
        if hermes_win:
            w_id = hermes_win.get("id")
            # Cukup panggil focus-window langsung dengan ID window-nya
            # Di Niri jika window berada di workspace lain, focus-window otomatis lompat ke window itu
            subprocess.run(["niri", "msg", "action", "focus-window", "--id", str(w_id)])
            return
            
        subprocess.Popen(["hermes", "desktop"])
    except Exception as e:
        print("Error focusing hermes:", e)

if __name__ == "__main__":
    focus_hermes()
