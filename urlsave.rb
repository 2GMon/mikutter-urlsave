# -*- coding: utf-8 -*-
# requrie 'date'
require 'net/http'
require 'cgi'
miquire :core, "serialthread"
miquire :addon, "settings"

Plugin::create(:urlsave) do
    settings("URLsave") do
        settings('基本設定') do
            input('ユーザー名', :urlsave_user)
            inputpass('パスワード', :urlsave_pass)
            boolean('URLsave起動', :urlsave_on)
        end
        settings("無視するURL") do
            multitext('無視するURL', :urlsave_ignore).
                tooltip('1行に一つrubyの正規表現で書く')
        end
    end

    @thread = SerialThreadGroup.new
    @https = Net::HTTP.new('www.instapaper.com', 443)
    @https.use_ssl = true
    onupdate do |service, message|
        @thread.new { instapaper(message) }
    end

    def instapaper(msg)
        if !msg.empty?
            msg.each do |m|
                get_url_message_entity(m).each do |e|
                    add_url(e)
                end
            end
        end
    end

    # URLが含まれるentityをとってるつもり
    # 誰がかっこいいメソッド名考えて
    def get_url_message_entity(msg)
        entity = msg.links.to_a
        result = []
        if entity.length != 0
            entity.each do |e|
                if e[:slug] == :urls
                    result << e[:message]
                end
            end
        end
        result
    end

    # InstapaperにURLを追加する
    def add_url(ent)
        if !UserConfig[:urlsave_latest_id].to_i
            UserConfig[:urlsave_latest_id] = ent[:id].to_i
        end
        if ent[:id].to_i > UserConfig[:urlsave_latest_id].to_i
            UserConfig[:urlsave_latest_id] = ent[:id].to_i
            urls = []
            ent[:entities][:urls].each do |u|
                if u[:expanded_url] != nil
                    urls << u[:expanded_url]
                else
                    urls << u[:url]
                end
            end
            call_api(ent[:id], ent[:message], urls) if UserConfig[:urlsave_on] && UserConfig[:urlsave_user]
        end
    end

    # API呼び出し
    def call_api(id, message, urls)
        urls.each do |u|
            if !ignore?(u)
                if !UserConfig[:urlsave_pass].empty?
                    res = @https.post('/api/add', 'username=' + UserConfig[:urlsave_user] +
                                      '&password=' + UserConfig[:urlsave_pass] + '&url=' +
                                      CGI.escape(u) + '&selection=' + CGI.escape(message))
                else
                    res = @https.post('/api/add', 'username=' + UserConfig[:urlsave_user] +
                                      '&url=' + CGI.escape(u) + '&selection=' + CGI.escape(message))
                end
                if res.code != "201"
                    error_api(id, message, u, res.code)
                end
            end
        end
    end

    # APIエラー
    def error_api(id, message, url, res)
        if res == "400"
            notify("Exceeded the rate limit.\nid : #{id}\npost : #{message}\nurl : #{url}")
        elsif res == "403"
            notify("Invalid username or password.\nid : #{id}\npost : #{message}\nurl : #{url}")
        else
            notify("The service encountered an error. Please try again later.\nid : #{id}\npost : #{message}\nurl : #{url}")
        end
    end

    # 無視するURL?
    def ignore?(url)
        ignore_list = UserConfig[:urlsave_ignore]
        ignore_list.split("\n").each do |i|
            r = Regexp.new(i)
            if r =~ url
#                notify("Ignored!!\nurl : #{url}")
                return true
            end
        end
        return false
    end

    def notify(msg)
        Plugin.call(:update, nil, [Message.new(:message => msg, :system => true)])
    end
end
