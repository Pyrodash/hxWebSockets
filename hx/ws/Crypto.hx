package hx.ws;

import haxe.io.Bytes;

class Crypto {
    static public function randomBytes(length:Int):Bytes {
        return haxe.io.Bytes.ofString(randomString(16));
    }

    public static function randomString(length:Int, ?charactersToUse = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"): String
    {
        var str = "";

        for (i in 0...length){
            str += charactersToUse.charAt( Math.floor((Math.random() *  (Date.now().getTime() % (charactersToUse.length) ) )));
        }

        return str;
    }
}