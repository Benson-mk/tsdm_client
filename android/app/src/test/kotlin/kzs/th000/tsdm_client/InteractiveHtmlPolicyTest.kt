package kzs.th000.tsdm_client

import android.net.Uri
import java.net.InetAddress
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class InteractiveHtmlPolicyTest {
    private val source = "https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266801"
    private fun content(html: String = "<button onclick=\"this.textContent='ok'\">Run</button>", account: String = "123", post: String = "42") =
        InteractiveHtmlPolicy.validate(html, source, account, post)

    @Test fun onlyVerifiedHttpsForumSourcesAreAccepted() {
        for (url in listOf("http://www.tsdm39.com/forum.php", "https://www.tsdm39.com.evil.example/forum.php",
            "https://evil.example/", "https://user:secret@www.tsdm39.com/forum.php", "https://www.tsdm39.com:444/forum.php",
            "javascript:alert(1)", "file:///tmp/forum.php", "https://localhost/")) {
            assertThrows(InteractiveHtmlPolicy.Failure::class.java) { InteractiveHtmlPolicy.validate("<p>x</p>", url, "guest", "42") }
        }
        assertEquals("https://tsdm39.com/", InteractiveHtmlPolicy.validate("x", "https://tsdm39.com/", "guest", "42").sourceUrl)
    }

    @Test fun payloadLimitCountsUtf8BytesNotOnlyCharacters() {
        val failure = assertThrows(InteractiveHtmlPolicy.Failure::class.java) { content("天".repeat(100_000)) }
        assertEquals("interactive_html_too_large", failure.code)
        assertThrows(InteractiveHtmlPolicy.Failure::class.java) { content("a".repeat(InteractiveHtmlPolicy.MAX_HTML_BYTES + 1)) }
        assertThrows(InteractiveHtmlPolicy.Failure::class.java) { content(account = " ") }
    }

    @Test fun storageOriginsAreStableAndSeparateAccountsPostsAndSourcePages() {
        val original = content()
        assertEquals(original.documentUrl, content().documentUrl)
        assertNotEquals(original.documentUrl, content(account = "guest").documentUrl)
        assertNotEquals(original.documentUrl, content(post = "43").documentUrl)
        assertNotEquals(original.documentUrl, InteractiveHtmlPolicy.validate("x", "$source&page=2", "123", "42").documentUrl)
        val uri = Uri.parse(original.documentUrl)
        assertEquals("https", uri.scheme)
        // The host itself is the registrable domain: no parent a cookie could be shared on.
        assertEquals(2, uri.host!!.split('.').size)
        assertTrue(uri.host!!.endsWith(".invalid"))
        assertTrue(uri.host!!.split('.').all { it.length <= 63 })
        assertNotEquals(uri.host, Uri.parse(content(account = "guest").documentUrl).host)
        assertFalse(original.documentUrl.contains("1266801"))
    }

    @Test fun originalInlineHtmlAndDomHandlersArePreservedUnderNetworkRestrictiveCsp() {
        val html = "<style>.card{color:red}</style><svg><path d='M1 1L2 2'/></svg><button onclick=\"localStorage.setItem('draft','hi');window.confirm('ok')\">Save</button>"
        val page = content(html)
        val document = InteractiveHtmlPolicy.document(page)
        assertTrue(document.contains(html))
        assertTrue(document.contains("<base href=\"https://www.tsdm39.com/forum.php?mod=viewthread&amp;tid=1266801\">"))
        val csp = InteractiveHtmlPolicy.headers(page).getValue("Content-Security-Policy")
        for (directive in listOf("script-src 'unsafe-inline'", "style-src 'unsafe-inline'", "connect-src 'none'",
            "frame-src 'none'", "worker-src 'none'", "form-action 'none'", "object-src 'none'", "default-src 'none'")) assertTrue(csp.contains(directive))
        assertFalse(csp.contains("unsafe-eval"))
        assertFalse(csp.contains("allow-popups"))
        assertEquals("no-referrer", InteractiveHtmlPolicy.headers(page)["Referrer-Policy"])
    }

    @Test fun declaredImagesResolveRelativeUrlsAndDoNotGrantDynamicImageRequests() {
        val page = content("""<img src="/data/a.png?x=1&amp;y=2"><source srcset="https://cdn.example.com/a.webp 1x, https://cdn.example.com/b.webp 2x"><svg><image xlink:href="https://cdn.example.com/c.png"/></svg><div style="background:url('/data/bg.png')"></div>""")
        assertEquals(setOf("https://www.tsdm39.com/data/a.png?x=1&y=2", "https://cdn.example.com/a.webp",
            "https://cdn.example.com/b.webp", "https://cdn.example.com/c.png", "https://www.tsdm39.com/data/bg.png"), page.imageUrls)
        InteractiveHtmlImages(page.imageUrls).use { loader ->
            assertEquals(403, loader.load("https://cdn.example.com/a.webp?draft=private").statusCode)
            assertEquals(403, loader.load("https://other.example.com/a.webp").statusCode)
            loader.close()
            assertEquals(403, loader.load("https://cdn.example.com/a.webp").statusCode)
        }
    }

    @Test fun localAndNonHttpsImagesAreNeverEligible() {
        for (url in listOf("http://cdn.example.com/a.png", "file:///etc/passwd", "content://contacts/1", "https://localhost/a",
            "https://a.local/a", "https://192.168.1.2/a", "https://127.0.0.1/a", "https://[::1]/a",
            "https://user:pass@cdn.example.com/a.png", "https://cdn.example.com:8443/a.png")) {
            assertNull(url, InteractiveHtmlPolicy.safeImageUrl(url))
        }
        assertNotNull(InteractiveHtmlPolicy.safeImageUrl("https://cdn.example.com/a.png"))
    }

    @Test fun dnsPolicyRejectsPrivateAndSpecialUseAddressesIncludingIpv6() {
        for (ip in listOf("0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254", "172.31.1.1",
            "192.168.1.1", "192.0.2.1", "198.18.0.1", "224.0.0.1", "::1", "fe80::1", "fd12::1", "2001:db8::1",
            "64:ff9b::a00:1", "64:ff9b::7f00:1", "64:ff9b::a9fe:a9fe")) {
            assertFalse(ip, InteractiveHtmlPolicy.publicAddress(InetAddress.getByName(ip)))
        }
        // 64:ff9b::808:808 is 8.8.8.8 through NAT64.
        for (ip in listOf("8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "64:ff9b::808:808")) {
            assertTrue(ip, InteractiveHtmlPolicy.publicAddress(InetAddress.getByName(ip)))
        }
    }

    @Test fun anchorsStayLocalOnlyForTheSourceAndSyntheticDocument() {
        val page = content()
        assertEquals("section", InteractiveHtmlPolicy.fragment(page, "$source#section"))
        assertEquals("section", InteractiveHtmlPolicy.fragment(page, "${page.documentUrl}#section"))
        assertNull(InteractiveHtmlPolicy.fragment(page, "https://evil.example/#section"))
        assertNull(InteractiveHtmlPolicy.fragment(page, source))
    }

    // #165: four nested quotes were squeezed into a column of a few characters by the browser's default indent.
    @Test fun forumQuotesAndLazyImagesRenderLikeTheForum() {
        val page = content("<blockquote><blockquote>x</blockquote></blockquote><img file=\"https://example.com/a.png\" onclick=\"zoom(this)\">")
        val document = InteractiveHtmlPolicy.document(page)
        assertTrue(document.contains("blockquote{margin:8px 0"))
        assertFalse(document.contains("overflow-wrap:anywhere"))
        assertTrue(document.contains("img[file]"))
        assertTrue("the placeholder is replaced too", document.contains("none\\.gif"))
        assertEquals(setOf("https://example.com/a.png"), page.imageUrls)
        assertTrue(InteractiveHtmlPolicy.declaredImageUrls("<img zoomfile='https://example.com/b.png'>", source).contains("https://example.com/b.png"))
        assertTrue(InteractiveHtmlPolicy.declaredImageUrls("<img data-file='https://example.com/c.png'>", source).isEmpty())
    }

    // #165: the viewer followed the system language instead of the one chosen in the app.
    @Test fun labelsFollowTheAppLanguage() {
        assertEquals("互动内容", InteractiveHtmlActivity.Labels.forLocale("zh-CN").title)
        assertEquals("互動內容", InteractiveHtmlActivity.Labels.forLocale("zh-TW").title)
        assertEquals("Interactive content", InteractiveHtmlActivity.Labels.forLocale("en").title)
        assertEquals("互動內容", InteractiveHtmlActivity.Labels.forLocale("zh-Hant").title)
    }

    // #165: closing the viewer closed the image sockets on the main thread and Android killed the app.
    @Test fun closingTheImageLoaderReturnsAtOnceAndRefusesNewLoads() {
        val images = InteractiveHtmlImages(setOf("https://example.com/a.png"))
        val caller = Thread.currentThread()
        images.close()
        images.close()
        assertSame(caller, Thread.currentThread())
        assertEquals(403, images.load("https://example.com/a.png").statusCode)
    }
}
