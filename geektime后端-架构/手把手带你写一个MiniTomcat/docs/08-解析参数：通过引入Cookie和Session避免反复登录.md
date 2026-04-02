你好，我是郭屹。今天我们继续手写MiniTomcat。

上一节课我们完成了对Request、Response的Header信息解析，并且采用Facade模式封装了我们希望暴露给外界的方法体，避免被业务程序员直接调用实现类的内部方法。

在实际的请求结构中，除了消息头部的参数之外，请求的URI后缀往往会带上请求参数，例如 `/app1/servlet1?username=Tommy&docid=TS0001`，路径和参数之间用“?”分隔，参数与参数之间使用“&amp;”隔开，这是我们这节课需要解析的部分。

除此之外，Header中可能还会包含用户信息，使用Cookie存储，但用户信息使用明文传递也不大好，而且Cookie是存储在客户端的，为了优化这个问题，Servlet规范规定了Session的用途，这节课我们也会解析并设置Cookie和Session。

下面我们一起动手来实现。

## 项目结构

这节课我们新增Session类，并对其进行封装而定义SessionFacade类。同时会增加TestServlet类，以便更好地测试。pom.xml依赖并未发生任何变化。项目结构如下：

```plain
MiniTomcat
├─ src
│  ├─ main
│  │  ├─ java
│  │  │  ├─ server
│  │  │  │  ├─ DefaultHeaders.java
│  │  │  │  ├─ HttpConnector.java
│  │  │  │  ├─ HttpHeader.java
│  │  │  │  ├─ HttpProcessor.java
│  │  │  │  ├─ HttpRequest.java
│  │  │  │  ├─ HttpRequestFacade.java
│  │  │  │  ├─ HttpRequestLine.java
│  │  │  │  ├─ HttpResponse.java
│  │  │  │  ├─ HttpResponseFacade.java
│  │  │  │  ├─ HttpServer.java
│  │  │  │  ├─ Request.java
│  │  │  │  ├─ Response.java
│  │  │  │  ├─ ServletProcessor.java
│  │  │  │  ├─ Session.java
│  │  │  │  ├─ SessionFacade.java
│  │  │  │  ├─ SocketInputStream.java
│  │  │  │  ├─ StatisResourceProcessor.java
│  │  ├─ resources
│  ├─ test
│  │  ├─ java
│  │  │  ├─ test
│  │  │  │  ├─ HelloServlet.java
│  │  │  │  ├─ TestServlet.java
│  │  ├─ resources
├─ webroot
│  ├─ test
│  │  ├─ HelloServlet.class
│  │  ├─ TestServlet.class
│  ├─ hello.txt
├─ pom.xml
```

## URI请求参数的解析

前面我们做到了解析Request Line一行，包括请求方法、URI与请求协议。但在实际请求中，URI后面经常会增加请求参数。比如：

```plain
GET /app1/servlet1?username=Tommy&docid=TS0001 HTTP/1.1
```

在这种情况下，以问号分隔的URI，前一部分是我们常说的请求地址，而后面则是请求的具体参数，接下来我们要把这部分的参数解析出来。

此前，在HttpRequest类的parse()方法中，我们已经用this.sis.readRequestLine(requestLine)这一行代码，获取到了Request Line。但我们把整个地址都当作了URI，因此有了下面这种写法。

```java
this.uri = new String(requestLine.uri,0,requestLine.uriEnd);
```

但现在我们需要截取一部分，将地址与参数分离，所以改写一下，新增parseRequestLine方法。

```java
public void parse(Socket socket) {
    try {
        parseConnection(socket);
        this.sis.readRequestLine(requestLine);
        parseRequestLine();
        parseHeaders();
    } catch (IOException e) {
        e.printStackTrace();
    } catch (ServletException e) {
        e.printStackTrace();
    }
}
private void parseRequestLine() {
		int question = requestLine.indexOf("?");
	    if (question >= 0) {
	        queryString=new String(requestLine.uri, question + 1, requestLine.uriEnd - question - 1);
	        uri = new String(requestLine.uri, 0, question);
	    } else {
	        queryString = null;
	        uri = new String(requestLine.uri, 0, requestLine.uriEnd);
	    }
    }
}
```

parseRequestLine方法比较简单，主要是判断路径里是否有问号，通过问号分隔，取出地址和参数。

上述考虑的主要是GET请求的处理，而POST请求则一般把请求参数放入请求体之中。我们来看一个POST请求的示例。

```plain
POST /test HTTP/1.1
Host: www.test.com
User-Agent: Mozilla/5.0(Windows; U; Windows NT 5.1; en-US; rv:1.7.6)Gecko/20050225 Firefox/1.0.1
Content-Type:application/x-www-form-urlencoded
Content-Length: 40
Connection: Keep-Alive

name=Professional%20Ajax&publisher=Wiley
```

我们可以看到，这种情况与GET请求类似，只是参数在请求体内，而且对URL做了encode编码，在这将一个空格转换成了%20。

接下来我们在HttpRequest类里定义数据结构用来存储参数信息。

```java
protected Map<String, String[]> parameters = new ConcurrentHashMap<>();
```

注意其中的value是字符串数组，因为部分参数存在多个值与之对应，例如options、checkbox等。

目前我们处理POST方法比较简单，只考虑文本类型。其实可以支持文本、二进制、压缩包，都是通过Content-Type指定。常见的有application/json、application/xml等。

还有POST可以混合，也就是multipart/form-data多部分，有的是文本，有的是二进制，比如图片之类的。我们现在也先暂时放到一边。

首先我们改造SocketInputStream，由继承InputStream改为继承ServletInputStream。你可以看一下完整代码。

```java
package server;
import javax.servlet.ReadListener;
import javax.servlet.ServletInputStream;
import java.io.IOException;
import java.io.InputStream;
public class SocketInputStream extends ServletInputStream {
    private static final byte CR = (byte) '\r';
    private static final byte LF = (byte) '\n';
    private static final byte SP = (byte) ' ';
    private static final byte HT = (byte) '\t';
    private static final byte COLON = (byte) ':';
    private static final int LC_OFFSET = 'A' - 'a';
    protected byte buf[];
    protected int count;
    protected int pos;
    protected InputStream is;
    public SocketInputStream(InputStream is, int bufferSize) {
        this.is = is;
        buf = new byte[bufferSize];
    }
    //按照格式解析请求行
    public void readRequestLine(HttpRequestLine requestLine)
        throws IOException {
        int chr = 0;
        do {
            try {
                chr = read();
            } catch (IOException e) {
            }
        } while ((chr == CR) || (chr == LF));
        pos--;
        int maxRead = requestLine.method.length;
        int readStart = pos;
        int readCount = 0;
        boolean space = false;
        //这里先获取请求的method
        while (!space) {
            if (pos >= count) {
                int val = read();
                if (val == -1) {
                    throw new IOException("requestStream.readline.error");
                }
                pos = 0;
                readStart = 0;
            }
            if (buf[pos] == SP) {
                space = true;
            }
            requestLine.method[readCount] = (char) buf[pos];
            readCount++;
            pos++;
        }
        requestLine.uriEnd = readCount - 1;
        maxRead = requestLine.uri.length;
        readStart = pos;
        readCount = 0;
        space = false;
        boolean eol = false;
        //再获取请求的uri
        while (!space) {
            if (pos >= count) {
                int val = read();
                if (val == -1)
                    throw new IOException("requestStream.readline.error");
                pos = 0;
                readStart = 0;
            }
            if (buf[pos] == SP) {
                space = true;
            }
            requestLine.uri[readCount] = (char) buf[pos];
            readCount++;
            pos++;
        }
        requestLine.uriEnd = readCount - 1;
        maxRead = requestLine.protocol.length;
        readStart = pos;
        readCount = 0;
        //最后获取请求的协议
        while (!eol) {
            if (pos >= count) {
                int val = read();
                if (val == -1)
                    throw new IOException("requestStream.readline.error");
                pos = 0;
                readStart = 0;
            }
            if (buf[pos] == CR) {
                // Skip CR.
            } else if (buf[pos] == LF) {
                eol = true;
            } else {
                requestLine.protocol[readCount] = (char) buf[pos];
                readCount++;
            }
            pos++;
        }
        requestLine.protocolEnd = readCount;
    }
    //读头信息，格式是header name:value
    public void readHeader(HttpHeader header)
        throws IOException {
        int chr = read();
        if ((chr == CR) || (chr == LF)) { // Skipping CR
            if (chr == CR)
                read(); // Skipping LF
            header.nameEnd = 0;
            header.valueEnd = 0;
            return;
        } else {
            pos--;
        }
        // 读取header名
        int maxRead = header.name.length;
        int readStart = pos;
        int readCount = 0;
        boolean colon = false;
        //以:分隔，前面的字符认为是header name
        while (!colon) {
            // 我们处于内部缓冲区的末尾
            if (pos >= count) {
                int val = read();
                if (val == -1) {
                    throw new IOException("requestStream.readline.error");
                }
                pos = 0;
                readStart = 0;
            }
            if (buf[pos] == COLON) {
                colon = true;
            }
            char val = (char) buf[pos];
            if ((val >= 'A') && (val <= 'Z')) {
                val = (char) (val - LC_OFFSET);
            }
            header.name[readCount] = val;
            readCount++;
            pos++;
        }
        header.nameEnd = readCount - 1;
        // 读取 header 值（可以多行）
        maxRead = header.value.length;
        readStart = pos;
        readCount = 0;
        int crPos = -2;
        boolean eol = false;
        boolean validLine = true;
        //处理行，因为一个header的值有可能多行(一行的前面是空格或者制表符)，需要连续处理
        while (validLine) {
            boolean space = true;
            // Skipping spaces
            // Note : 只有前面的空格被跳过
            while (space) {
                // We're at the end of the internal buffer
                if (pos >= count) {
                    // Copying part (or all) of the internal buffer to the line
                    // buffer
                    int val = read();
                    if (val == -1)
                        throw new IOException("requestStream.readline.error");
                    pos = 0;
                    readStart = 0;
                }
                if ((buf[pos] == SP) || (buf[pos] == HT)) {
                    pos++;
                } else {
                    space = false;
                }
            }
            //一直处理到行结束
            while (!eol) {
                // We're at the end of the internal buffer
                if (pos >= count) {
                    // Copying part (or all) of the internal buffer to the line
                    // buffer
                    int val = read();
                    if (val == -1)
                        throw new IOException("requestStream.readline.error");
                    pos = 0;
                    readStart = 0;
                }
                //回车换行表示行结束
                if (buf[pos] == CR) {
                } else if (buf[pos] == LF) {
                    eol = true;
                } else {
                    int ch = buf[pos] & 0xff;
                    header.value[readCount] = (char) ch;
                    readCount++;
                }
                pos++;
            }
            //再往前读一个字符，如果是空格或制表符号则继续，多行处理的情况
            int nextChr = read();
            if ((nextChr != SP) && (nextChr != HT)) {
                pos--;
                validLine = false;
            } else {
                eol = false;
                header.value[readCount] = ' ';
                readCount++;
            }
        }
        header.valueEnd = readCount;
    }
    @Override
    public int read() throws IOException {
        if (pos >= count) {
            fill();
            if (pos >= count) {
                return -1;
            }
        }
        return buf[pos++] & 0xff;
    }
    public int available() throws IOException {
        return (count - pos) + is.available();
    }
    public void close() throws IOException {
        if (is == null) {
            return;
        }
        is.close();
        is = null;
        buf = null;
    }
    protected void fill() throws IOException {
        pos = 0;
        count = 0;
        int nRead = is.read(buf, 0, buf.length);
        if (nRead > 0) {
            count = nRead;
        }
    }
    @Override
    public boolean isFinished() {
        return false;
    }
    @Override
    public boolean isReady() {
        return false;
    }
    @Override
    public void setReadListener(ReadListener readListener) {
    }
}
```

随后在HttpRequest的parseParameters方法内，我们就可以通过getInputStream()方法读取请求体内容。

```java
protected void parseParameters() {
    //设置字符集
    String encoding = getCharacterEncoding();
    if (encoding == null) {
        encoding = "ISO-8859-1";
    }
    //获取查询串
    String qString = getQueryString();
    if (qString != null) {
        byte[] bytes = new byte[qString.length()];
        try {
            bytes=qString.getBytes(encoding);
            parseParameters(this.parameters, bytes, encoding);
        } catch (UnsupportedEncodingException e) {
            e.printStackTrace();;
        }
    }
    //获取 content Type
    String contentType = getContentType();
    if (contentType == null)
        contentType = "";
    int semicolon = contentType.indexOf(';');
    if (semicolon >= 0) {
        contentType = contentType.substring(0, semicolon).trim();
    }
    else {
        contentType = contentType.trim();
    }
    //对POST方法，从body中解析参数
    if ("POST".equals(getMethod()) && (getContentLength() > 0)
            && "application/x-www-form-urlencoded".equals(contentType)) {
        try {
            int max = getContentLength();
            int len = 0;
            byte buf[] = new byte[getContentLength()];
            ServletInputStream is = getInputStream();
            while (len < max) {
                int next = is.read(buf, len, max - len);
                if (next < 0) {
                    break;
                }
                len += next;
            }
            is.close();
            if (len < max) {
                throw new RuntimeException("Content length mismatch");
            }
            parseParameters(this.parameters, buf, encoding);
        }
        catch (UnsupportedEncodingException ue) {
        }
        catch (IOException e) {
            throw new RuntimeException("Content read fail");
        }
    }
}

//十六进制字符到数字的转换
private byte convertHexDigit(byte b) {
    if ((b >= '0') && (b <= '9')) return (byte)(b - '0');
    if ((b >= 'a') && (b <= 'f')) return (byte)(b - 'a' + 10);
    if ((b >= 'A') && (b <= 'F')) return (byte)(b - 'A' + 10);
    return 0;
}
public void parseParameters(Map<String,String[]> map, byte[] data, String encoding)
        throws UnsupportedEncodingException {
    if (parsed)
        return;
    if (data != null && data.length > 0) {
        int    pos = 0;
        int    ix = 0;
        int    ox = 0;
        String key = null;
        String value = null;
        //解析参数串，处理特殊字符
        while (ix < data.length) {
            byte c = data[ix++];
            switch ((char) c) {
                case '&':   //两个参数之间的分隔符，遇到这个字符保存已经解析的key和value
                    value = new String(data, 0, ox, encoding);
                    if (key != null) {
                        putMapEntry(map,key, value);
                        key = null;
                    }
                    ox = 0;
                    break;
                case '=': //参数的key/value的分隔符
                    key = new String(data, 0, ox, encoding);
                    ox = 0;
                    break;
                case '+': //特殊字符，空格
                    data[ox++] = (byte)' ';
                    break;
                case '%': //处理%NN表示的ASCII字符
                    data[ox++] = (byte)((convertHexDigit(data[ix++]) << 4)
                            + convertHexDigit(data[ix++]));
                    break;
                default:
                    data[ox++] = c;
            }
        }
        //最后一个参数没有&结尾
        //The last value does not end in '&'.  So save it now.
        if (key != null) {
            value = new String(data, 0, ox, encoding);
            putMapEntry(map,key, value);
        }
    }
    parsed = true;
}
//给key设置新值，多值用数组来存储
private static void putMapEntry( Map<String,String[]> map, String name, String value) {
    String[] newValues = null;
    String[] oldValues = (String[]) map.get(name);
    if (oldValues == null) {
        newValues = new String[1];
        newValues[0] = value;
    } else {
        newValues = new String[oldValues.length + 1];
        System.arraycopy(oldValues, 0, newValues, 0, oldValues.length);
        newValues[oldValues.length] = value;
    }
    map.put(name, newValues);
}
```

我们通过getInputStream方法，一次性将字节流读入到buf\[]里，统一通过 `parseParameters(Map<String,String[]> map, byte[] data, String encoding)` 重载方法进行处理。在这个方法中主要进行参数解析：依次读取byte，在这个过程中判断 “&amp;”“=”“+”等特殊字符。而且对于“%20”这样经过encode的字符要特殊处理，我们要用十六进制还原它的字符。

你可以看一下解析代码。

```java
    private byte convertHexDigit(byte b) {
        if ((b >= '0') && (b <= '9')) return (byte)(b - '0');
        if ((b >= 'a') && (b <= 'f')) return (byte)(b - 'a' + 10);
        if ((b >= 'A') && (b <= 'F')) return (byte)(b - 'A' + 10);
        return 0;
    }
```

先拿到“2”这个字符，变成数字2，再拿到“0”这个字符，变成数字0，随后进行计算：2\*16+0=32，再按照ascii变成字符，也就是空格。

```java
(byte)((convertHexDigit(data[ix++]) << 4) + convertHexDigit(data[ix++]));
```

最后我们完善HttpRequest类中与parameter相关的方法。

```java
	public String getParameter(String name) {
	    parseParameters();
	    String values[] = (String[]) parameters.get(name);
	    if (values != null)
	      return (values[0]);
	    else
	      return (null);	}

	public Map<String, String[]> getParameterMap() {
	    parseParameters();
	    return (this.parameters);
	}

	public Enumeration<String> getParameterNames() {
	    parseParameters();
	    return (Collections.enumeration(parameters.keySet()));
	}

	public String[] getParameterValues(String name) {
	    parseParameters();
	    String values[] = (String[]) parameters.get(name);
	    if (values != null)
	      return (values);
	    else
	      return null;
	}
```

这里我们初步完成了HttpRequest类里对请求参数parameter的解析，所有的处理都是在获取到具体参数的时候，才调用parseParameters()方法，把时序放到这里，是为了性能考虑。

## 引入Cookie和Session

在处理完参数解析之后，我们接下来考虑解析Cookie，Cookie也是放在Header里的，固定格式是 `Cookie: userName=xxxx;password=pwd;`，因此我们再次解析Header的时候，如果发现Header的名称是Cookie，就进一步解析Cookie。因为Cookie的数据结构需要遵从javax.servlet.http.Cookie规定，而request里可以包含多个Cookie，所以我们会用数组来存储。

在解析Cookie后我们再看一下Session，其实这两部分的改造可以放在一起，所以我们后续一并讨论。

HTTP协议本身是无状态的，但是在网站登录后我们又不希望一跳转页面就需要重新输入账号密码登录，在这种情况下就需要记住第一次登录状态，而Servlet规范就规定了使用Session记住用户状态，定义接口为javax.servlet.http.HttpSession。

Session由服务器创建，存在SessionID，依靠URL或者是Cookie传送，把名称定义成jsessionid。今后浏览器与服务器之间的数据交换都带上这个jsessionid. 然后程序可以根据jsessionid拿到这个Session，把一些状态数据存储在Session里。

一个Session其实可以简单地看成一个Map结构，然后由我们的Server为每个客户端创建一个Session。

首先我们先定义Session类与SessionFacade类，用来处理Server中的逻辑。

Session.java类定义如下：

```java
package server;
public class Session implements HttpSession{
    private String sessionid;
    private long creationTime;
    private boolean valid;
    private Map<String,Object> attributes = new ConcurrentHashMap<>();
    @Override
    public long getCreationTime() {
        return this.creationTime;
    }
    @Override
    public String getId() {
        return this.sessionid;
    }
    @Override
    public long getLastAccessedTime() {
        return 0;
    }
    @Override
    public ServletContext getServletContext() {
        return null;
    }
    @Override
    public void setMaxInactiveInterval(int interval) {
    }
    @Override
    public int getMaxInactiveInterval() {
        return 0;
    }
    @Override
    public HttpSessionContext getSessionContext() {
        return null;
    }
    @Override
    public Object getAttribute(String name) {
        return this.attributes.get(name);
    }
    @Override
    public Object getValue(String name) {
        return this.attributes.get(name);
    }
    @Override
    public Enumeration<String> getAttributeNames() {
        return Collections.enumeration(this.attributes.keySet());
    }
    @Override
    public String[] getValueNames() {
        return null;
    }
    @Override
    public void setAttribute(String name, Object value) {
        this.attributes.put(name, value);
    }
    @Override
    public void putValue(String name, Object value) {
        this.attributes.put(name, value);
    }
    @Override
    public void removeAttribute(String name) {
        this.attributes.remove(name);
    }
    @Override
    public void removeValue(String name) {
    }
    @Override
    public void invalidate() {
        this.valid = false;
    }
    @Override
    public boolean isNew() {
        return false;
    }
    public void setValid(boolean b) {
        this.valid = b;
    }
    public void setCreationTime(long currentTimeMillis) {
        this.creationTime = currentTimeMillis;
    }
    public void setId(String sessionId) {
        this.sessionid = sessionId;
    }
}
```

SessionFacade.java类定义如下：

```java
package server;
public class SessionFacade implements HttpSession{
    private HttpSession session;
    public SessionFacade(HttpSession session) {
        this.session = session;
    }
    @Override
    public long getCreationTime() {
        return session.getCreationTime();
    }
    @Override
    public String getId() {
        return session.getId();
    }
    @Override
    public long getLastAccessedTime() {
        return session.getLastAccessedTime();
    }
    @Override
    public ServletContext getServletContext() {
        return session.getServletContext();
    }
    @Override
    public void setMaxInactiveInterval(int interval) {
        session.setMaxInactiveInterval(interval);
    }
    @Override
    public int getMaxInactiveInterval() {
        return session.getMaxInactiveInterval();
    }
    @Override
    public HttpSessionContext getSessionContext() {
        return session.getSessionContext();
    }
    @Override
    public Object getAttribute(String name) {
        return session.getAttribute(name);
    }
    @Override
    public Object getValue(String name) {
        return session.getValue(name);
    }
    @Override
    public Enumeration<String> getAttributeNames() {
        return session.getAttributeNames();
    }
    @Override
    public String[] getValueNames() {
        return session.getValueNames();
    }
    @Override
    public void setAttribute(String name, Object value) {
        session.setAttribute(name, value);
    }
    @Override
    public void putValue(String name, Object value) {
        session.putValue(name, value);
    }
    @Override
    public void removeAttribute(String name) {
        session.removeAttribute(name);
    }
    @Override
    public void removeValue(String name) {
        session.removeValue(name);
    }
    @Override
    public void invalidate() {
        session.invalidate();
    }
    @Override
    public boolean isNew() {
        return session.isNew();
    }
}
```

通过上面的定义实现可以看出，Session类主要是作为javax.servlet.http.HttpSession接口的实现类，而SessionFacade类则封装了希望对外暴露的接口，隐藏我们内部的实现。

我们需要明确，创建Session的是Server，也就是Servlet容器，比如Tomcat或者MiniTomcat。而客户端Client对Servlet的处理流程里只是使用Session存储的数据。程序员通过 `HttpServletRequest#getSession()` 获取返回的HttpSession。

Servlet容器根据收到的HTTP请求创建Session，也可以在客户端程序调用getSession方法的时候创建。上述过程完毕之后，Response返回参数内会回写Sessionid，这是通过在响应头中设置set-cookie参数实现的。

整个Session创建获取的情况是这样的：

1. 对一个全新的客户端发送HTTP请求到Server：Server发现这是一个全新的请求，为它创建Session，分配Sessionid，并在Response的返回头中设置Set-Cookie。生成的Session可能存放了某些身份认证识别的内容。
2. 客户端再次请求，这次在请求头Cookie内带上回传的Sessionid：Server发现第二次请求带有Sessionid，根据id匹配到Session，并取出之前存放在Session里的内容。

我们要明确一个事实，虽然我们一直将Cookie与Session放在一起来讲，甚至有可能将二者混为一谈，但Session不一定要依赖Cookie（某些时候存在设置不接受Cookie的情况），也可以通过URL中参数带的jsessionid来做到，比如 `/test/TestServlet;jsessionid=5AC6268DD8D4D5D1FDF5D41E9F2FD960?curAlbumID=9`。浏览器是在URL之后加上 `;jsessionid=` 这个固定搭配来传递Session，不是普通的参数格式。

接下来我们看看怎么处理。首先是接收请求时在HttpRequest类中解析Session。提取parseRequestLine公共方法，你可以看一下HttpRequest类完整定义，接口实现类我只列出有调整的。

```java
package server;

public class HttpRequest implements HttpServletRequest {
    private InputStream input;
    private SocketInputStream sis;
    private String uri;
    private String queryString;
    InetAddress address;
    int port;
    private boolean parsed = false;
    protected HashMap<String, String> headers = new HashMap<>();
    protected Map<String, String[]> parameters = new ConcurrentHashMap<>();
    HttpRequestLine requestLine = new HttpRequestLine();
    Cookie[] cookies;
    HttpSession session;
    String sessionid;
    SessionFacade sessionFacade;
    public HttpRequest(InputStream input) {
        this.input = input;
        this.sis = new SocketInputStream(this.input, 2048);
    }
    //解析请求行和头header
    public void parse(Socket socket) {
        try {
            parseConnection(socket);
            this.sis.readRequestLine(requestLine);
            parseRequestLine();
            parseHeaders();
        } catch (IOException e) {
            e.printStackTrace();
        } catch (ServletException e) {
            e.printStackTrace();
        }
    }
    //处理请求行
    private void parseRequestLine() {
        //以问号判断是否带有参数串
        int question = requestLine.indexOf("?");
        if (question >= 0) {
            queryString = new String(requestLine.uri, question + 1, requestLine.uriEnd - question - 1);
            uri = new String(requestLine.uri, 0, question);
            //处理参数串中带有jsessionid的情况
            int semicolon = uri.indexOf(DefaultHeaders.JSESSIONID_NAME);
            if (semicolon >= 0) {
                sessionid = uri.substring(semicolon+DefaultHeaders.JSESSIONID_NAME.length());
                uri = uri.substring(0, semicolon);
            }
        } else {
            queryString = null;
            uri = new String(requestLine.uri, 0, requestLine.uriEnd);
            int semicolon = uri.indexOf(DefaultHeaders.JSESSIONID_NAME);
            if (semicolon >= 0) {
                sessionid = uri.substring(semicolon+DefaultHeaders.JSESSIONID_NAME.length());
                uri = uri.substring(0, semicolon);
            }
        }
    }
    private void parseConnection(Socket socket) {
        address = socket.getInetAddress();
        port = socket.getPort();
    }
    //解析所有header信息
    private void parseHeaders() throws IOException, ServletException {
        while (true) {
            HttpHeader header = new HttpHeader();
            sis.readHeader(header);
            if (header.nameEnd == 0) {
                if (header.valueEnd == 0) {
                    return;
                } else {
                    throw new ServletException("httpProcessor.parseHeaders.colon");
                }
            }
            String name = new String(header.name,0,header.nameEnd);
            String value = new String(header.value, 0, header.valueEnd);
            // 设置相应的头信息
            if (name.equals(DefaultHeaders.ACCEPT_LANGUAGE_NAME)) {
                headers.put(name, value);
            } else if (name.equals(DefaultHeaders.CONTENT_LENGTH_NAME)) {
                headers.put(name, value);
            } else if (name.equals(DefaultHeaders.CONTENT_TYPE_NAME)) {
                headers.put(name, value);
            } else if (name.equals(DefaultHeaders.HOST_NAME)) {
                headers.put(name, value);
            } else if (name.equals(DefaultHeaders.CONNECTION_NAME)) {
                headers.put(name, value);
            } else if (name.equals(DefaultHeaders.TRANSFER_ENCODING_NAME)) {
                headers.put(name, value);
            } else if (name.equals(DefaultHeaders.COOKIE_NAME)) {
                headers.put(name, value);
                //处理cookie和session
                Cookie[] cookiearr = parseCookieHeader(value);
                this.cookies = cookiearr;
                for (int i = 0; i < cookies.length; i++) {
                    if (cookies[i].getName().equals("jsessionid")) {
                        this.sessionid = cookies[i].getValue();
                    }
                }
            }
            else {
                headers.put(name, value);
            }
        }
    }
    //解析Cookie头，格式为: key1=value1;key2=value2
    public  Cookie[] parseCookieHeader(String header) {
        if ((header == null) || (header.length() < 1) )
            return (new Cookie[0]);
        ArrayList<Cookie> cookieal = new ArrayList<>();
        while (header.length() > 0) {
            int semicolon = header.indexOf(';');
            if (semicolon < 0)
                semicolon = header.length();
            if (semicolon == 0)
                break;
            String token = header.substring(0, semicolon);
            if (semicolon < header.length())
                header = header.substring(semicolon + 1);
            else
                header = "";
            try {
                int equals = token.indexOf('=');
                if (equals > 0) {
                    String name = token.substring(0, equals).trim();
                    String value = token.substring(equals+1).trim();
                    cookieal.add(new Cookie(name, value));
                }
            } catch (Throwable e) {
            }
        }
        return ((Cookie[]) cookieal.toArray (new Cookie [cookieal.size()]));
    }
    
    @Override
    public Cookie[] getCookies() {
        return this.cookies;
    }
    
    @Override
    public HttpSession getSession() {
        return this.sessionFacade;
    }
    //如果有存在的session，直接返回，如果没有，创建一个新的session
    public HttpSession getSession(boolean create) {
        if (sessionFacade != null)
            return sessionFacade;
        if (sessionid != null) {
            session = HttpConnector.sessions.get(sessionid);
            if (session != null) {
                sessionFacade = new SessionFacade(session);
                return sessionFacade;
            } else {
                session = HttpConnector.createSession();
                sessionFacade = new SessionFacade(session);
                return sessionFacade;
            }
        } else {
            session = HttpConnector.createSession();
            sessionFacade = new SessionFacade(session);
            sessionid = session.getId();
            return sessionFacade;
        }
    }
    public String getSessionId() {
        return this.sessionid;
    }
}
```

上述代码中，我们着重关注parseRequestLine与parseCookieHeader方法的实现，主要是解析URL里包含jsessionid的部分，以及从Cookie中获取jsessionid。

但这个时候我们只是获取到了id，并没有获取Session，按照程序执行的顺序，如果在URL的查询字符串与Cookie中都存在jsessonid，那么我们会优先获取Cookie里对应的这个值。

由于我们一个Server需要对应多个Client，所以在Server内我们考虑采用Map结构存储Session，其中Key为Sessionid，Value为Session认证信息。因为HttpConnector类是全局的，所以现在我们先把这个Map存放在HttpConnector类里。同时将createSession方法以及generateSesionId方法也都放在HttpConnector中。你可以看一下相关代码。

```java
package server;
public class HttpConnector implements Runnable {
    int minProcessors = 3;
    int maxProcessors = 10;
    int curProcessors = 0;
    Deque<HttpProcessor> processors = new ArrayDeque<>();
    //sessions map存放session
    public static Map<String, HttpSession> sessions = new ConcurrentHashMap<>();
    //创建新的session
    public static Session createSession() {
        Session session = new Session();
        session.setValid(true);
        session.setCreationTime(System.currentTimeMillis());
        String sessionId = generateSessionId();
        session.setId(sessionId);
        sessions.put(sessionId, session);
        return (session);
    }
    //以随机方式生成byte数组,形成sessionid
    protected static synchronized String generateSessionId() {
        Random random = new Random();
        long seed = System.currentTimeMillis();
        random.setSeed(seed);
        byte bytes[] = new byte[16];
        random.nextBytes(bytes);
        StringBuffer result = new StringBuffer();
        for (int i = 0; i < bytes.length; i++) {
            byte b1 = (byte) ((bytes[i] & 0xf0) >> 4);
            byte b2 = (byte) (bytes[i] & 0x0f);
            if (b1 < 10)
                result.append((char) ('0' + b1));
            else
                result.append((char) ('A' + (b1 - 10)));
            if (b2 < 10)
                result.append((char) ('0' + b2));
            else
                result.append((char) ('A' + (b2 - 10)));
        }
        return (result.toString());
    }
}
```

将Session的生成和管理全部放在Connector内还是有点儿臃肿，后面我们会进一步分解功能，通过Container和Manager来管理Session，现在暂且不深入讨论。

因为HttpConnector会在接受Socket之后，为Processor分配Socket，所以我们先在HttpProcessor类中进行Session处理。

添加代码：

```java
            // create Request object and parse
            HttpRequest request = new HttpRequest(input);
            request.parse(socket);
            
            //handle session
            if (request.getSessionId()==null || request.getSessionId().equals("")) {
              request.getSession(true);
            }

            // create Response object
            HttpResponse response = new HttpResponse(output);
            response.setRequest(request);
```

代码里注释为“handle session”的代码就是我们添加的，判断是否存在Sessionid，不存在则调用getSession方法，这个方法内会判断有没有Session，如果没有就创建。目前还存在一个问题，当Request请求每次都是新创建的，那么Session一定是空的，所以在getSession方法内我们会进一步判断在URL中是否存在jsessionid，如果解析后的结果中有jsessionid，我们会用这个jsessionid从HttpConnector类的全局Map里查找相应的Session。

## 测试

这节课我们在src/test/java/test目录下引入新的TestServlet进行测试。

```java
package test;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import javax.servlet.http.HttpSession;
import java.io.IOException;
public class TestServlet extends HttpServlet{
    private static final long serialVersionUID = 1L;
    @Override
    public void doGet(HttpServletRequest request, HttpServletResponse response)throws ServletException, IOException {
        System.out.println("Enter doGet()");
        System.out.println("parameter name : "+request.getParameter("name"));
        HttpSession session = request.getSession(true);
        String user = (String) session.getAttribute("user");
        System.out.println("get user from session : " + user);
        if (user == null || user.equals("")) {
            session.setAttribute("user", "yale");
        }
        response.setCharacterEncoding("UTF-8");
        String doc = "<!DOCTYPE html> \n" +
                "<html>\n" +
                "<head><meta charset=\"utf-8\"><title>Test</title></head>\n"+
                "<body bgcolor=\"#f0f0f0\">\n" +
                "<h1 align=\"center\">" + "Test 你好" + "</h1>\n";
        System.out.println(doc);
        response.getWriter().println(doc);
    }
    public void doPost(HttpServletRequest request, HttpServletResponse response)throws ServletException, IOException {
        System.out.println("Enter doGet()");
        System.out.println("parameter name : "+request.getParameter("name"));
        response.setCharacterEncoding("UTF-8");
        String doc = "<!DOCTYPE html> \n" +
                "<html>\n" +
                "<head><meta charset=\"utf-8\"><title>Test</title></head>\n"+
                "<body bgcolor=\"#f0f0f0\">\n" +
                "<h1 align=\"center\">" + "Test 你好" + "</h1>\n";
        System.out.println(doc);
        response.getWriter().println(doc);
    }
}
```

启动程序，调用发送请求的时候，程序会依据GET或者POST请求，分别调用doGet和doPost方法。Servlet程序中直接使用下面这段代码获取Session。

```java
public void doGet(HttpServletRequest request, HttpServletResponse response)throws ServletException, IOException {
    HttpSession session = request.getSession(true);
}
```

如果用户知道内部的实现，可以将这个Session强行转换，这样会暴露出很多内部使用的方法，因此在这里我们也会用SessionFacade包装一下，request参数内传入的就是SessionFacade的对象。

## 小结

这节课我们做到了对URI的参数解析，适配常规GET请求，另外一件事则是引入Cookie和Session的解析与处理，支持存储数据，避免多次反复登录。但目前还有个遗留问题，为了多次往返的时候带上jsessionid，我们需要在Response返回参数中回写，让客户端程序也能获取到，应该怎么处理呢？如果你有兴趣的话，可以继续往后看，我们后续会继续改造。

本节课完整代码参见：[https://gitee.com/yaleguo1/minit-learning-demo/tree/geek\_chapter08](https://gitee.com/yaleguo1/minit-learning-demo/tree/geek_chapter08)

## 思考题

学完了这节课的内容，我们做一个练习：自己手工写一个完整的请求串，要求包含cookie和session，并且某一个头的值是多行的。

欢迎你把你写的请求串分享到评论区，也欢迎你把这节课的内容分享给其他朋友，我们下节课再见！
<div><strong>精选留言（5）</strong></div><ul>
<li><span>ctt</span> 👍（1） 💬（1）<p>GET &#47;path&#47;to&#47;resource HTTP&#47;1.1
Host: www.example.com
User-Agent: Mozilla&#47;5.0 (Windows NT 10.0; Win64; x64) AppleWebKit&#47;537.36
             (KHTML, like Gecko) Chrome&#47;58.0.3029.110 Safari&#47;537.36
Accept: text&#47;html,application&#47;xhtml+xml,application&#47;xml;q=0.9,image&#47;webp,*&#47;*;q=0.8
Accept-Language: en-US,en;q=0.5
Accept-Encoding: gzip, deflate, br
Cookie: sessionid=abc123; username=ctt
Connection: keep-alive
</p>2023-12-27</li><br/><li><span>peter</span> 👍（0） 💬（1）<p>请教老师几个问题：
Q1：Cookie和Session是成对出现的吗？
有Cookie就一定有Session，对吗？反过来，有Session也一定有Cookie，对吗？
Q2：Session的Set-Cookie字段可以出现多次吗？
我让chatGPT3.5给出一个包含Cookie的Http响应，给出的例子是：
HTTP&#47;1.1 200 OK
Date: Tue, 15 Nov 2022 08:12:31 GMT
Server: Apache&#47;2.4.38 (Unix)
Set-Cookie: sessionid=abc123; Expires=Wed, 16 Nov 2022 08:12:31 GMT; Path=&#47;
Set-Cookie: username=johndoe; Expires=Wed, 16 Nov 2022 08:12:31 GMT; Path=&#47;
Content-Type: text&#47;html; charset=utf-8
Content-Length: 1234

其中，Set-Cookie出现了两次。
我问gpt为什么出现两次，gpt回答“常抱歉，我犯了一个错误。在HTTP响应中，Set-Cookie首部字段只能出现一次”，但给出的修正后的例子还是包含两个。
请问：Http Response的Set-Cookie字段可以出现多次吗？


Q3:本课代码，messaging包不存在
HttpRequest.java文件中有如下导包语句：
import com.sun.xml.internal.messaging.saaj.packaging.mime.internet.InternetHeaders;
编译报错：
Error:(3, 67) java: 程序包com.sun.xml.internal.messaging.saaj.packaging.mime.internet不存在
前面几课的代码，Idea中修改java版本后都能正常运行，第8课的代码却有这个编译错误，为什么？</p>2023-12-25</li><br/><li><span>HH🐷🐠</span> 👍（0） 💬（2）<p>1、手工写一个请求串
POST &#47;servlet&#47;test.TestServlet HTTP&#47;1.1
Host: localhost:8080
Content-Type: application&#47;x-www-form-urlencoded
Cookie: jsessionid=43C65BC81B4B4DE4623CD48A13E7FF84; userId=123
Content-Length: 9

name=haha

2、回传 jsessionid 到客户端其实文中也有提到了， 通过 cookie  或 URL 重写进行进行回传。</p>2023-12-25</li><br/><li><span>夙夜SEngineer</span> 👍（0） 💬（0）<p>我来完善一段代码逻辑，getParameter(String name)方法中，应只调用一次parseParameters，添加if (parameters.isEmpty())判断：
    @Override
    public String getParameter(String name) {
        if (parameters.isEmpty()) {
            parseParameters();
        }
        String values[] = parameters.get(name);
        if (values != null)
            return (values[0]);
        else
            return (null);
    }
否则遇到POST请求体多个参数解析的时候，由于SocketInputStream提前关闭导致fill函数中is引用空指针异常
    protected void fill() throws IOException {
        pos = 0;
        count = 0;
        int nRead = is.read(buf, 0, buf.length);
        if (nRead &gt; 0) {
            count = nRead;
        }
    }</p>2025-02-12</li><br/><li><span>偶来人间，风度翩翩</span> 👍（0） 💬（1）<p>代码示例中，对于SocketInputStream类，
第53行代码【requestLine.uriEnd =  readCount - 1; 】是不正确的，
应该是【requestLine.methodEnd = readCount - 1;】。   </p>2024-05-25</li><br/>
</ul>